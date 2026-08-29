require "mcp"
require "set"

module Mcp
  module Tools
    class WriteMemoryTool < MCP::Tool
      extend MemoryToolSupport

      tool_name "write_memory"

      DUPLICATE_LOOKBACK = 14.days
      DUPLICATE_SIMILARITY_THRESHOLD = 0.82
      DUPLICATE_PREFIX_LENGTH = 80

      description "Write a persistent memory. In chat sessions the scope can be " \
                  "'global' (personal) or 'repository' (tied to a repository). " \
                  "In workflow runs the scope is always 'repository' and is set " \
                  "automatically; author, source_type, and source_id are derived " \
                  "from the agent run context."

      input_schema(
        properties: {
          content:  { type: "string", maxLength: ChatMemory::CONTENT_MAX_LENGTH, description: "Memory content (max #{ChatMemory::CONTENT_MAX_LENGTH} characters)." },
          kind:     { type: "string", enum: ChatMemory::KIND, description: "Memory kind." },
          scope:    { type: "string", enum: ChatMemory::TOOL_SCOPES, description: "Memory scope: global or repository. Omit to default to repository in workflow runs." },
          scope_id: { type: "integer", description: "Repository id when scope is 'repository'. Required in chat sessions; inferred from run context in workflow runs." }
        },
        required: %w[content kind]
      )

      class << self
        def call(content:, kind:, server_context:, scope: nil, scope_id: nil)
          context = McpToolContext.from_server_context(server_context)
          content = content.to_s.strip
          kind    = kind.to_s

          return invalid_response("content is required") if content.empty?
          if content.length > ChatMemory::CONTENT_MAX_LENGTH
            return invalid_response(
              "content is #{content.length} characters; write_memory content must be " \
              "#{ChatMemory::CONTENT_MAX_LENGTH} characters or fewer. Store one concise " \
              "durable fact per memory, or split independent facts into separate memories."
            )
          end
          return invalid_response("kind must be one of #{ChatMemory::KIND.join(', ')}") unless ChatMemory::KIND.include?(kind)

          effective_scope = resolve_scope(context, scope)
          return effective_scope if effective_scope.is_a?(MCP::Tool::Response)

          repository = nil
          if effective_scope == "repository"
            repository = resolve_repository(context, scope_id)
            return repository if repository.is_a?(MCP::Tool::Response)
          elsif scope_id.present?
            return invalid_response("scope_id must be omitted for global memories")
          end

          author, source_type, source_id = run_provenance(context)
          policy_rejection = MemoryWritePolicy.for(context).rejection_for(content)
          return invalid_response(policy_rejection) if policy_rejection

          if (duplicate = duplicate_memory_for(context, content, kind, effective_scope, repository&.id))
            return invalid_response(
              "similar #{kind} memory already exists as ChatMemory ##{duplicate.id}; " \
              "read_memory that id and update or delete it instead of creating a duplicate"
            )
          end

          memory = ChatMemory.create!(
            user:        context.user,
            content:     content,
            kind:        kind,
            scope:       effective_scope,
            scope_id:    repository&.id,
            author:      author,
            source_type: source_type,
            source_id:   source_id
          )

          success_response(id: memory.id, memory: memory_payload(memory))
        rescue ActiveRecord::RecordInvalid => e
          invalid_response(e.record.errors.full_messages.to_sentence)
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::WriteMemoryTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def resolve_scope(context, requested_scope)
          if requested_scope.present?
            scope = requested_scope.to_s
            unless context.allowed_memory_scopes.include?(scope)
              return invalid_response("scope must be one of #{context.allowed_memory_scopes.join(', ')}")
            end

            scope
          else
            context.allowed_memory_scopes.first
          end
        end

        def resolve_repository(context, scope_id)
          if context.run?
            context.repository
          else
            repo = writable_repository_for(context, scope_id)
            repo || invalid_response("scope_id must be a repository id owned by the current user")
          end
        end

        def run_provenance(context)
          if context.run?
            [ "agent", "run", context.run.id ]
          else
            [ nil, nil, nil ]
          end
        end

        def duplicate_memory_for(context, content, kind, scope, scope_id)
          ChatMemory.active
                    .where(user: context.user, kind: kind, scope: scope, scope_id: scope_id)
                    .where(created_at: DUPLICATE_LOOKBACK.ago..)
                    .order(created_at: :desc)
                    .detect { |memory| duplicate_content?(memory.content, content) }
        end

        def duplicate_content?(existing_content, new_content)
          existing_normalized = normalize_duplicate_text(existing_content)
          new_normalized = normalize_duplicate_text(new_content)
          return false if existing_normalized.blank? || new_normalized.blank?

          existing_normalized.first(DUPLICATE_PREFIX_LENGTH) == new_normalized.first(DUPLICATE_PREFIX_LENGTH) ||
            trigram_jaccard(existing_normalized, new_normalized) >= DUPLICATE_SIMILARITY_THRESHOLD
        end

        def normalize_duplicate_text(content)
          content.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
        end

        def trigram_jaccard(left, right)
          left_trigrams = trigrams(left)
          right_trigrams = trigrams(right)
          return 1.0 if left_trigrams.empty? && right_trigrams.empty?
          return 0.0 if left_trigrams.empty? || right_trigrams.empty?

          (left_trigrams & right_trigrams).size.fdiv((left_trigrams | right_trigrams).size)
        end

        def trigrams(text)
          padded = "  #{text}  "
          return [ padded ] if padded.length < 3

          padded.each_char.each_cons(3).map(&:join).to_set
        end
      end
    end
  end
end
