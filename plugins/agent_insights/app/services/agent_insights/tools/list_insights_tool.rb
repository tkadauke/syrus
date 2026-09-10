require "mcp"

module AgentInsights
  module Tools
    # MCP tool for insight agents and chat agents to list Suggestion
    # records. Run-sidecar calls are scoped to the current run's repository.
    # Chat-sidecar calls are scoped to the current operator: admins can list
    # globally, non-admins are limited to the chat's attached repositories.
    class ListInsightsTool < MCP::Tool
      STATES = (Suggestion::STATES + %w[all]).freeze

      tool_name "list_insights"

      description <<~DESC
        List Suggestion records visible in the current context. Filter by
        repository_id, state (pending/accepted/dismissed/all), and page; results
        are paginated newest-first.
      DESC

      input_schema(
        properties: {
          repository_id: {
            type: "integer",
            description: "Optional Repository id. Required only when you want to narrow broad/admin results."
          },
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

        def call(server_context:, repository_id: nil, state: nil, limit: nil, page: nil)
          state_s = state.to_s.presence || "all"
          return Mcp::Tools.invalid("state must be one of: #{STATES.join(', ')}") unless STATES.include?(state_s)

          context = McpToolContext.from_server_context(server_context)
          scope = visible_scope(context, repository_id: repository_id)
          return scope if scope.is_a?(MCP::Tool::Response)

          scope = scope.where(state: state_s) unless state_s == "all"

          per_page = normalized_limit(limit, default: DEFAULT_LIMIT, max: MAX_LIMIT)
          page_num = [Integer(page.presence || 1, exception: false) || 1, 1].max
          offset   = (page_num - 1) * per_page

          insights = scope
            .includes(:repository, job: { runs: { step: :workflow } })
            .order(created_at: :desc, id: :desc)
            .limit(per_page)
            .offset(offset)

          include_repository = context.chat?
          MCP::Tool::Response.new([
            {
              type: "text",
              text: JSON.generate(
                insights: insights.map do |insight|
                  list_payload(insight, include_repository: include_repository)
                end
              )
            }
          ])
        rescue StandardError => e
          Rails.logger.error("[Mcp::Tools::ListInsightsTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def visible_scope(context, repository_id:)
          scope = Suggestion.all

          if context.run?
            requested_id = normalized_repository_id(repository_id)
            return invalid_repository_id(repository_id) if repository_id.present? && requested_id.nil?

            repository = context.repository || context.run&.job&.repository
            return not_accessible(repository_id) if requested_id && requested_id != repository&.id

            return scope.for_repository(repository)
          end

          requested_id = normalized_repository_id(repository_id)
          return invalid_repository_id(repository_id) if repository_id.present? && requested_id.nil?

          if context.user.admin?
            requested_id ? scope.where(repository_id: requested_id) : scope
          else
            allowed_ids = context.allowed_repository_ids
            return not_accessible(repository_id) if requested_id && !allowed_ids.include?(requested_id)

            scope.where(repository_id: requested_id || allowed_ids)
          end
        end

        def normalized_repository_id(value)
          Integer(value, exception: false) if value.present?
        end

        def not_accessible(repository_id)
          MCP::Tool::Response.new(
            [ { type: "text", text: "Error: repository not found or not accessible: #{repository_id}" } ],
            error: true
          )
        end

        def invalid_repository_id(repository_id)
          Mcp::Tools.invalid("repository_id must be an integer: #{repository_id}")
        end

        def normalized_limit(value, default:, max:)
          n = Integer(value.presence || default, exception: false)
          n ? n.clamp(1, max) : default
        end

        def list_payload(insight, include_repository:)
          payload = {
            id:         insight.id,
            title:      insight.redacted_title,
            category:   insight.redacted_category,
            state:      insight.state,
            proposal_type: insight.effective_proposal_type,
            severity:   insight.severity,
            confidence: insight.confidence,
            job:        job_payload(insight.job),
            source_workflow: workflow_payload(source_workflow(insight)),
            source_run: run_payload(source_run(insight)),
            created_at: insight.created_at.iso8601,
            updated_at: insight.updated_at.iso8601
          }
          if include_repository
            payload[:repository] = {
              id: insight.repository_id,
              slug: insight.repository.slug
            }
          end
          payload
        end

        def source_run(insight)
          insight.job.runs.last
        end

        def source_workflow(insight)
          source_run(insight)&.workflow || insight.job.workflows.last
        end

        def job_payload(job)
          return nil unless job

          {
            id: job.id,
            slug: job.slug,
            title: job_title(job),
            path: "/jobs/#{job.id}"
          }
        end

        def job_title(job)
          job.issue_title.presence || job.title
        end

        def workflow_payload(workflow)
          return nil unless workflow

          {
            id: workflow.id,
            slug: workflow.slug,
            path: "/jobs/#{workflow.job_id}?tab=workflows#workflow-#{workflow.id}"
          }
        end

        def run_payload(run)
          return nil unless run

          {
            id: run.id,
            slug: run.slug,
            path: "/admin/runs/#{run.id}/transcript"
          }
        end
      end
    end
  end
end
