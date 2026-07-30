require "mcp"

module SyrusMcp
  # MCP tool for insight agents to read the full details of a single
  # InsightSuggestion record. Authorization is enforced via repository
  # scope: the insight must belong to the current run's repository.
  class ReadInsightTool < MCP::Tool
    tool_name "read_insight"

    description <<~DESC
      Read the full details of a single InsightSuggestion record.
      Only accessible when it belongs to the current run's repository.
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
        run        = SyrusMcp.run_from_context(server_context)
        repository = run.job.repository

        insight = InsightSuggestion.for_repository(repository).find_by(id: id)

        unless insight
          return MCP::Tool::Response.new(
            [ { type: "text", text: "Error: insight not found or not accessible: #{id}" } ],
            error: true
          )
        end

        MCP::Tool::Response.new([
          { type: "text", text: JSON.generate(insight: full_payload(insight)) }
        ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ReadInsightTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def full_payload(insight)
        {
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
      end
    end
  end
end
