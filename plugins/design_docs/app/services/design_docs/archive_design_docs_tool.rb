require "mcp"

module DesignDocs
  class ArchiveDesignDocsTool < MCP::Tool
    extend ToolSupport
    extend ::Mcp::Tools::BulkPendingActionToolSupport

    MAX_DOCS = ::Mcp::Tools::BulkPendingActionToolSupport::MAX_BATCH_SIZE

    tool_name "archive_design_docs"

    description "Archive multiple Design Docs with one operator confirmation. Prefer this tool over repeated delete_design_doc calls for multi-document requests. Requires canonical DOC-<id> references and one shared audit reason; already archived docs are reported and skipped."

    input_schema(
      properties: {
        doc_refs: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          maxItems: MAX_DOCS,
          description: "One to #{MAX_DOCS} canonical DOC-<id> references. Duplicates are removed while preserving first-seen order."
        },
        reason: { type: "string", minLength: 1, description: "Shared audit reason for archiving every eligible Design Doc." }
      },
      required: %w[doc_refs reason]
    )

    class << self
      def call(doc_refs:, reason:, server_context:)
        return invalid("archive_design_docs is only available in chat contexts") unless chat_context?(server_context)

        normalized_refs, error = normalize_refs(doc_refs)
        return invalid(error) if error
        return invalid("reason must not be blank") if reason.to_s.strip.blank?

        context = context_from(server_context)
        docs = resolve_all!(normalized_refs, context)
        archived, eligible = docs.partition { |doc| doc.state == "archived" }

        if eligible.empty?
          return success(response_payload(nil, normalized_refs, eligible, archived, reason, state: "skipped"))
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: context.chat_session,
          reason: reason.to_s.strip,
          member_attributes: eligible.map do |design_doc|
            {
              action: "delete_design_doc",
              requested_by: "agent",
              reason: reason.to_s.strip,
              payload: ArchivePreview.payload(design_doc)
            }
          end
        )

        success(response_payload(group, normalized_refs, eligible, archived, reason, state: group.state))
      rescue ActiveRecord::RecordNotFound, Pundit::NotAuthorizedError
        invalid("one or more design docs are unavailable in this agent context or cannot be archived")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::ArchiveDesignDocsTool] #{e.class}: #{e.message}")
        tool_error("Could not prepare Design Docs for archiving: #{e.message}")
      end

      private

      def normalize_refs(doc_refs)
        return [ nil, "doc_refs must be an array" ] unless doc_refs.is_a?(Array)
        return [ nil, "doc_refs must not be empty" ] if doc_refs.empty?
        return [ nil, "doc_refs may contain at most #{MAX_DOCS} targets" ] if doc_refs.size > MAX_DOCS

        normalized = doc_refs.map do |value|
          match = value.to_s.strip.match(/\ADOC-(\d+)\z/i)
          return [ nil, "every doc_ref must be a canonical DOC-<id> reference" ] unless match

          "DOC-#{match[1].to_i}"
        end
        [ normalized.uniq, nil ]
      end

      def resolve_all!(refs, context)
        docs = refs.map { |ref| find_design_doc!(ref, context) }
        raise Pundit::NotAuthorizedError unless docs.all? { |doc| DesignDocPolicy.new(context.user, doc).archive? }

        docs
      end

      def response_payload(group, requested_refs, eligible, archived, reason, state:)
        anchor = group&.chat_pending_actions&.first
        {
          pending_action_group_id: group&.id,
          pending_action_id: anchor&.id,
          pending_confirmation_id: anchor&.id,
          requested_refs: requested_refs,
          eligible_count: eligible.size,
          skipped_count: archived.size,
          skipped: archived.map { |doc| { doc_ref: doc.display_id, title: doc.title, reason: "already archived" } },
          targets: eligible.map { |doc| { doc_ref: doc.display_id, title: doc.title } },
          reason: reason.to_s.strip,
          state: state,
          member_count: eligible.size,
          confirmation_required: group.present?,
          message: group ? "Archive #{eligible.size} Design Docs?" : "All requested Design Docs were already archived."
        }
      end
    end
  end
end
