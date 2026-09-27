require "mcp"

module OperatorBriefing
  module Tools
    class ListRecentWorkflowsTool < MCP::Tool
      tool_name "list_briefing_recent_workflows"

      description <<~DESC
        List completed Workflows for the current briefing run's repository in
        the briefing window. Results include run summaries and review artifacts.
      DESC

      input_schema(
        properties: {
          limit: {
            type: "integer",
            description: "Maximum workflows per page. Defaults to 20, capped at 50."
          },
          page: {
            type: "integer",
            description: "Page number, 1-based. Defaults to 1."
          }
        }
      )

      class << self
        include McpToolPayloads::WorkflowPayload

        DEFAULT_LIMIT = 20
        MAX_LIMIT = 50

        def call(server_context:, limit: nil, page: nil)
          run = Mcp::Tools.run_from_context(server_context)
          briefing = Briefing.find_by!(job: run.job)
          per_page = normalized_limit(limit)
          page_num = normalized_page(page)
          scope = workflow_scope(briefing)

          total = scope.count
          workflows = scope.offset((page_num - 1) * per_page).limit(per_page)
          MCP::Tool::Response.new([
            {
              type: "text",
              text: JSON.generate(
                repository: { id: briefing.repository_id, slug: briefing.repository.slug },
                window_start: briefing.window_start.iso8601,
                window_end: briefing.window_end.iso8601,
                total_workflows: total,
                page: page_num,
                per: per_page,
                total_pages: total_pages(total, per_page),
                workflows: workflows.map { |workflow| workflow_payload(workflow) }
              )
            }
          ])
        rescue StandardError => e
          Rails.logger.error("[OperatorBriefing::ListRecentWorkflowsTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def workflow_scope(briefing)
          ::Workflow
            .joins(:job)
            .includes(:job, :workflow_warnings, steps: :runs)
            .where(jobs: { repository_id: briefing.repository_id, user_id: briefing.owner_user_id })
            .where.not(jobs: { kind: ActivityGate::EXCLUDED_JOB_KINDS })
            .where.not(finished_at: nil)
            .where(finished_at: briefing.window_start..briefing.window_end)
            .order(finished_at: :desc, id: :desc)
        end

        def workflow_payload(workflow)
          runs = workflow_step_runs(workflow)
          latest_run = latest_run_for(runs)
          {
            id: workflow.id,
            job: {
              id: workflow.job_id,
              kind: workflow.job.kind,
              state: workflow.job.state,
              title: text_snippet(redact(workflow.job.title), 200),
              path: "/jobs/#{workflow.job_id}"
            },
            trigger_kind: workflow.trigger_kind,
            state: workflow.state,
            agent_provider: workflow.agent_provider,
            summary: text_snippet(redact(workflow.artifact("summary").presence || latest_run&.agent_summary), 500),
            review_artifacts: review_artifacts(workflow),
            step_count: workflow.steps.size,
            run_count: runs.size,
            started_at: workflow.started_at&.iso8601,
            finished_at: workflow.finished_at&.iso8601,
            runs: runs.map { |run| run_payload(run) },
            warnings: workflow.workflow_warnings.map { |warning| warning_payload(warning) }
          }
        end

        def review_artifacts(workflow)
          {
            adversarial_review_iterations: CommandRedactor.redact_value(workflow.artifact("adversarial_review_iterations")),
            visual_review_iterations: CommandRedactor.redact_value(workflow.artifact("visual_review_iterations"))
          }.compact
        end

        def warning_payload(warning)
          {
            id: warning.id,
            kind: warning.kind,
            severity: warning.severity,
            title: text_snippet(redact(warning.title), 200),
            evidence: CommandRedactor.redact_value(warning.evidence),
            state: warning.state,
            created_job_id: warning.created_job_id,
            created_at: warning.created_at&.iso8601
          }
        end

        def run_payload(run)
          {
            id: run.id,
            step_kind: run.step&.kind,
            state: run.state,
            agent_outcome: run.agent_outcome,
            agent_summary: text_snippet(redact(run.agent_summary), 300),
            started_at: run.started_at&.iso8601,
            finished_at: run.finished_at&.iso8601
          }
        end

        def normalized_limit(value)
          n = Integer(value.presence || DEFAULT_LIMIT, exception: false)
          n ? n.clamp(1, MAX_LIMIT) : DEFAULT_LIMIT
        end

        def normalized_page(value)
          [ Integer(value.presence || 1, exception: false) || 1, 1 ].max
        end

        def total_pages(total, per)
          return 0 if total.zero?

          (total.to_f / per).ceil
        end

        def redact(value)
          ::Mcp::Tools::EvidenceRedactor.call(value)
        end
      end
    end
  end
end
