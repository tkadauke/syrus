require "mcp"

module SyrusMcp
  # MCP tool for insight agents to list InsightSuggestion records for the
  # current run's repository. Scoped to the repository; supports state
  # filtering and offset-based pagination.
  class ListInsightsTool < MCP::Tool
    STATES = (InsightSuggestion::STATES + %w[all]).freeze

    tool_name "list_insights"

    description <<~DESC
      List InsightSuggestion records for the current run's repository.
      Filter by state (pending/accepted/dismissed/all); results are paginated
      newest-first.
    DESC

    input_schema(
      properties: {
        state: {
          type: "string",
          enum: STATES,
          description: "Filter by state: pending, accepted, dismissed, or all (default: all)."
        },
        limit: {
          type: "integer",
          description: "Maximum results per page (default: 20, max: 50)."
        },
        page: {
          type: "integer",
          description: "Page number, 1-based (default: 1)."
        }
      }
    )

    class << self
      MAX_LIMIT     = 50
      DEFAULT_LIMIT = 20

      def call(server_context:, state: nil, limit: nil, page: nil)
        run        = SyrusMcp.run_from_context(server_context)
        repository = run.job.repository

        state_s = state.to_s.presence || "all"
        return SyrusMcp.invalid("state must be one of: #{STATES.join(', ')}") unless STATES.include?(state_s)

        scope   = InsightSuggestion.for_repository(repository)
        scope   = scope.where(state: state_s) unless state_s == "all"

        per_page = normalized_limit(limit, default: DEFAULT_LIMIT, max: MAX_LIMIT)
        page_num = [Integer(page.presence || 1, exception: false) || 1, 1].max
        offset   = (page_num - 1) * per_page

        insights = scope.order(created_at: :desc, id: :desc).limit(per_page).offset(offset)

        MCP::Tool::Response.new([
          { type: "text", text: JSON.generate(insights: insights.map { |i| list_payload(i) }) }
        ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ListInsightsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalized_limit(value, default:, max:)
        n = Integer(value.presence || default, exception: false)
        n ? n.clamp(1, max) : default
      end

      def list_payload(insight)
        {
          id:         insight.id,
          title:      insight.title,
          state:      insight.state,
          severity:   insight.severity,
          confidence: insight.confidence,
          created_at: insight.created_at.iso8601
        }
      end
    end
  end
end
