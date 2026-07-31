require "mcp"

module SyrusMcp
  class ListRecentWorkflowsTool < MCP::Tool
    tool_name "list_recent_workflows"

    description <<~DESC
      List recent completed Workflows for the current insight run's repository.
      Results are scoped to the current repository and default to the analysis
      window after the previous agent_insight Job finished.
    DESC

    input_schema(
      properties: {
        since: {
          type: "string",
          description: "Optional ISO8601 cutoff. Defaults to the previous agent_insight Job finished_at, or 14 days ago."
        },
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

      def call(server_context:, since: nil, limit: nil, page: nil)
        context_run = SyrusMcp.run_from_context(server_context)
        repository = context_run.job.repository
        cutoff = parse_since(since) || default_cutoff(context_run)
        per_page = normalized_limit(limit)
        page_num = normalized_page(page)

        scope = Workflow
          .joins(:job)
          .includes(:job, steps: :runs)
          .where(jobs: { repository_id: repository.id, user_id: context_run.job.user_id })
          .where.not(jobs: { kind: "agent_insight" })
          .where.not(finished_at: nil)
          .where("workflows.finished_at >= ?", cutoff)
          .order(finished_at: :desc, id: :desc)

        total = scope.count
        workflows = scope.offset((page_num - 1) * per_page).limit(per_page)

        MCP::Tool::Response.new([
          {
            type: "text",
            text: JSON.generate(
              repository: { id: repository.id, slug: repository.slug },
              since: cutoff.iso8601,
              total_workflows: total,
              page: page_num,
              per: per_page,
              total_pages: total_pages(total, per_page),
              workflows: workflows.map { |workflow| workflow_payload(workflow) }
            )
          }
        ])
      rescue ArgumentError => e
        SyrusMcp.invalid(e.message)
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::ListRecentWorkflowsTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def parse_since(value)
        raw = value.to_s.strip
        return if raw.empty?

        Time.iso8601(raw)
      rescue ArgumentError
        raise ArgumentError, "since must be a valid ISO8601 timestamp"
      end

      def default_cutoff(context_run)
        previous_insight = context_run.job.repository.jobs
          .where(kind: "agent_insight")
          .where.not(id: context_run.job_id)
          .where.not(finished_at: nil)
          .order(finished_at: :desc)
          .first

        previous_insight&.finished_at || 14.days.ago
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

      def workflow_payload(workflow)
        runs = workflow_step_runs(workflow)
        latest_run = latest_run_for(runs)
        {
          id: workflow.id,
          job: {
            id: workflow.job_id,
            kind: workflow.job.kind,
            state: workflow.job.state,
            title: text_snippet(redact(workflow.job.title), 200)
          },
          trigger_kind: workflow.trigger_kind,
          state: workflow.state,
          agent_provider: workflow.agent_provider,
          summary: text_snippet(redact(workflow.artifact("summary").presence || latest_run&.agent_summary), 500),
          step_count: workflow.steps.size,
          run_count: runs.size,
          started_at: workflow.started_at&.iso8601,
          finished_at: workflow.finished_at&.iso8601,
          runs: runs.map { |run| run_payload(run) }
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

      def redact(value)
        SyrusMcp::EvidenceRedactor.call(value)
      end
    end
  end
end
