require "mcp"

module Mcp::Tools
  class SearchJobsTool < MCP::Tool
    tool_name "search_jobs"

    description "Search Syrus Jobs across all the current user's repositories by title and stored body text."

    input_schema(
      properties: {
        query: { type: "string", description: "Search text. Minimum length 2." },
        state: { type: "string", description: "Optional exact Job state filter." },
        limit: { type: "integer", description: "Maximum Jobs to return. Defaults to 20, capped at 100." }
      },
      required: %w[query]
    )

    class << self
      include McpToolPayloads::JobPayload

      def call(server_context:, query:, state: nil, limit: 20)
        context = McpToolContext.from_server_context(server_context)
        query = query.to_s.strip
        return Mcp::Tools.invalid("query must be at least 2 characters") if query.length < 2

        scope = job_scope(context)
        scope = scope.where(state: state.to_s) if state.to_s.strip.present?
        scope = apply_search(scope, query)
        total = scope.count

        Mcp::Tools.success(
          total: total,
          results: scope
            .order(updated_at: :desc, id: :desc)
            .limit(normalize_limit(limit))
            .preload(:repository)
            .map { |job| job_search_payload(job) }
        )
      end

      private

      def job_scope(context)
        if context.run?
          Job.accessible_to(context.user).where(repository_id: context.allowed_repository_ids)
        elsif context.user.admin?
          Job.all
        else
          Job.accessible_to(context.user)
        end
      end

      def normalize_limit(value)
        value.to_i.clamp(1, 100)
      end

      def apply_search(scope, query)
        term = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
        table = Job.arel_table
        columns = ([ "issue_title" ] + optional_search_columns).uniq
        predicate = columns
          .map { |column| Arel::Nodes::NamedFunction.new("LOWER", [ table[column] ]).matches(term) }
          .reduce { |combined, node| combined.or(node) }

        scope.where(predicate)
      end

      def optional_search_columns
        Job.column_names & %w[body description issue_body]
      end
    end
  end
end
