require "mcp"

module AgentInsights
  module Tools
    # MCP tool for insight agents and chat agents to read the full details of a
    # single Suggestion record. Authorization is enforced via repository
    # scope: run-sidecar calls are limited to the current run's repository; chat
    # calls are limited to the current operator's allowed chat repositories unless
    # the operator is an admin.
    class ReadInsightTool < MCP::Tool
      tool_name "read_insight"

      description <<~DESC
        Read the full details of a single Suggestion record.
        Only accessible when it belongs to a repository visible in the current
        context.
      DESC

      input_schema(
        properties: {
          id: {
            type: "integer",
            description: "Suggestion id."
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
          Rails.logger.error("[Mcp::Tools::ReadInsightTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def visible_scope(context)
          scope = Suggestion.includes(:repository, job: { runs: { step: :workflow } })

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
            title:             insight.redacted_title,
            category:          insight.redacted_category,
            severity:          insight.severity,
            confidence:        insight.confidence,
            state:             insight.state,
            proposal_type:     insight.effective_proposal_type,
            evidence:          insight.redacted_evidence,
            suggested_prompt:  insight.redacted_suggested_prompt,
            memory_suggestion: insight.redacted_memory_suggestion,
            target_memory_id:  insight.target_memory_id,
            stale_memory_text: insight.redacted_stale_memory_text,
            stale_memory_evidence: insight.redacted_stale_memory_evidence,
            target_insight_id: insight.target_insight_id,
            retired_at:        insight.retired_at&.iso8601,
            retired_reason:    insight.redacted_retired_reason,
            superseded_by_insight_id: insight.superseded_by_insight_id,
            superseded_by_job_id:     insight.superseded_by_job_id,
            job:               job_payload(insight.job),
            source_workflow:    workflow_payload(source_workflow(insight)),
            source_run:         run_payload(source_run(insight)),
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
            title: job.issue_title.presence || job.title,
            path: "/jobs/#{job.id}"
          }
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
