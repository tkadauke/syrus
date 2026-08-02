require "mcp"

module SyrusMcp
  # MCP tool for insight agents and chat agents to read the full details of a
  # single InsightSuggestion record. Authorization is enforced via repository
  # scope: run-sidecar calls are limited to the current run's repository; chat
  # calls are limited to the current operator's allowed chat repositories unless
  # the operator is an admin.
  class ReadInsightTool < MCP::Tool
    tool_name "read_insight"

    description <<~DESC
      Read the full details of a single InsightSuggestion record.
      Only accessible when it belongs to a repository visible in the current
      context.
    DESC

    input_schema(
      properties: {
        id: {
          type: "integer",
          description: "InsightSuggestion id."
        }
      },
      required: %w[id]
    )

    class << self
      def call(id:, server_context:)
        context = McpToolContext.from_server_context(server_context)
        insight = visible_scope(context).find_by(id: id)

        unless insight
          return MCP::Tool::Response.new(
            [ { type: "text", text: "Error: insight not found or not accessible: #{id}" } ],
            error: true
          )
        end

        MCP::Tool::Response.new([
          { type: "text", text: JSON.generate(insight: full_payload(insight, include_repository: context.chat?)) }
        ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadInsightTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def visible_scope(context)
        scope = InsightSuggestion.includes(:job, :repository)

        if context.run?
          repository = context.repository || context.run&.job&.repository
          scope.for_repository(repository)
        elsif context.user.admin?
          scope
        else
          scope.where(repository_id: context.allowed_repository_ids)
        end
      end

      def full_payload(insight, include_repository:)
        payload = {
          id:                insight.id,
          title:             insight.title,
          category:          insight.category,
          severity:          insight.severity,
          confidence:        insight.confidence,
          state:             insight.state,
          evidence:          insight.evidence,
          suggested_prompt:  insight.suggested_prompt,
          memory_suggestion: insight.memory_suggestion,
          job:               { id: insight.job_id, title: insight.job.title },
          created_at:        insight.created_at.iso8601,
          updated_at:        insight.updated_at.iso8601
        }
        if include_repository
          payload[:repository] = {
            id: insight.repository_id,
            slug: insight.repository.slug
          }
        end
        payload
      end
    end
  end
end
