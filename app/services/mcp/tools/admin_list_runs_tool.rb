require "mcp"

module Mcp::Tools
  class AdminListRunsTool < MCP::Tool
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    tool_name "admin_list_runs"

    description "List Runs across all Jobs with optional state, trigger, Job, and since filters."

    input_schema(
      properties: {
        state: { type: "string", description: "Optional Run state filter." },
        trigger_kind: { type: "string", description: "Optional Run trigger kind filter." },
        job_id: { type: "integer", description: "Optional Job id filter." },
        since: { type: "string", description: "Optional ISO8601 lower bound on finished, started, or created time." },
        limit: { type: "integer", description: "Maximum rows to return. Defaults to 20." }
      }
    )

    class << self
      def call(state: nil, trigger_kind: nil, job_id: nil, since: nil, limit: DEFAULT_LIMIT, server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)

        scope = Run.includes(step: :workflow).order(Arel.sql("COALESCE(finished_at, started_at, created_at) DESC"))
        scope = scope.where(state: state) if state.present?
        scope = scope.where(trigger_kind: trigger_kind) if trigger_kind.present?
        scope = scope.where(job_id: job_id) if job_id.present?
        scope = scope.where("COALESCE(finished_at, started_at, created_at) >= ?", Time.iso8601(since)) if since.present?

        runs = scope.limit(normalize_limit(limit)).map { |run| run_payload(run) }
        Mcp::Tools.success(runs: runs)
      rescue ArgumentError, TypeError
        Mcp::Tools.invalid("since must be ISO8601")
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def normalize_limit(limit)
        limit.to_i.clamp(1, MAX_LIMIT)
      end

      def run_payload(run)
        {
          id: run.id,
          job_id: run.job_id,
          workflow_id: run.step&.workflow_id,
          state: run.state,
          trigger_kind: run.trigger_kind,
          started_at: run.started_at&.iso8601,
          finished_at: run.finished_at&.iso8601,
          cost_usd: run.cost_usd&.to_s
        }
      end
    end
  end
end
