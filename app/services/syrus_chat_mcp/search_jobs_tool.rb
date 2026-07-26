require "mcp"

module SyrusChatMcp
  class SearchJobsTool < MCP::Tool
    tool_name "search_jobs"

    description "Search Syrus Jobs across all the current user's repositories by title and stored body text."

    input_schema(
      properties: {
        query: { type: "string", description: "Search text. Minimum length 2." },
        state: { type: "string", description: "Optional exact Job state filter." },
        limit: { type: "integer", description: "Maximum Jobs to return. Defaults to 20, capped at 50." }
      },
      required: %w[query]
    )

    class << self
      def call(server_context:, query:, state: nil, limit: 20)
        chat_session = server_context.fetch(:chat_session)
        query = query.to_s.strip
        return SyrusChatMcp.invalid("query must be at least 2 characters") if query.length < 2

        scope = chat_session.user.admin? ? Job.all : chat_session.user.jobs
        scope = scope.where(state: state.to_s) if state.to_s.strip.present?
        scope = apply_search(scope, query)
        total = scope.count

        SyrusChatMcp.success(
          total: total,
          results: scope.order(updated_at: :desc, id: :desc).limit(normalize_limit(limit)).map { |job| job_payload(job) }
        )
      end

      private

      def normalize_limit(value)
        value.to_i.clamp(1, 50)
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

      def job_payload(job)
        {
          id: job.id,
          repository_slug: job.repository&.slug,
          kind: job.kind,
          issue_title: job.issue_title,
          state: job.state,
          pr_number: job.pr_number || job.external_pr_number,
          priority: job.priority,
          created_at: job.created_at&.iso8601,
          updated_at: job.updated_at&.iso8601
        }
      end
    end
  end
end
