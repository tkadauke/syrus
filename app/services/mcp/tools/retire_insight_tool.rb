require "mcp"

module Mcp::Tools
  # MCP tool for insight agents to retire a stale, duplicated, or superseded
  # InsightSuggestion with an audit trail. Retirement is a state transition
  # (state: "retired"), never a physical delete, so historical evidence stays
  # inspectable via list_insights(state: "retired"/"all") and read_insight.
  class RetireInsightTool < MCP::Tool
    tool_name "retire_insight"

    description <<~DESC
      Retires a stale, duplicated, or superseded InsightSuggestion with an
      audit trail. Use this instead of filing a new informational
      "Superseded by #N" card to clear a stale pending or dismissed insight.
      Accepted insights are operator history and are refused by default;
      pass retire_accepted: true only when the accepted insight itself is
      confirmed obsolete, not merely superseded by newer work (prefer filing
      a new standalone insight in that case).
    DESC

    input_schema(
      properties: {
        target_insight_id: {
          type: "integer",
          description: "Required InsightSuggestion id to retire."
        },
        reason: {
          type: "string",
          description: "Required concise reason for the audit trail explaining why this finding is no longer current."
        },
        superseded_by_insight_id: {
          type: "integer",
          description: "Optional id of the InsightSuggestion that supersedes this one."
        },
        superseded_by_job_id: {
          type: "integer",
          description: "Optional id of the Job that resolved or replaced this finding."
        },
        retire_accepted: {
          type: "boolean",
          description: "Set true to retire an accepted insight. Refused unless explicitly set; prefer filing a new standalone insight instead."
        }
      },
      required: %w[target_insight_id reason]
    )

    class << self
      def call(target_insight_id:, reason:, server_context:,
               superseded_by_insight_id: nil, superseded_by_job_id: nil, retire_accepted: false)
        run = Mcp::Tools.run_from_context(server_context)
        reason_s = CommandRedactor.redact(Mcp::Tools.utf8(reason)).strip
        return Mcp::Tools.invalid("reason is required") if reason_s.empty?

        insight = visible_insight(target_insight_id, run)
        return Mcp::Tools.invalid("target_insight_id must reference an accessible insight") unless insight
        return Mcp::Tools.invalid("InsightSuggestion ##{insight.id} is already retired.") if insight.retired?

        if insight.accepted? && !retire_accepted
          return Mcp::Tools.invalid(
            "InsightSuggestion ##{insight.id} is accepted and cannot be retired without retire_accepted: true. " \
            "Prefer filing a new standalone insight that supersedes it; only pass retire_accepted: true when this " \
            "accepted insight itself is confirmed obsolete."
          )
        end

        superseding_insight = nil
        if superseded_by_insight_id.present?
          superseding_insight = visible_insight(superseded_by_insight_id, run)
          return Mcp::Tools.invalid("superseded_by_insight_id must reference an accessible insight in the current repository") unless superseding_insight
          return Mcp::Tools.invalid("superseded_by_insight_id cannot reference the insight being retired") if superseding_insight.id == insight.id
        end

        superseding_job = nil
        if superseded_by_job_id.present?
          superseding_job = visible_job(superseded_by_job_id, run)
          return Mcp::Tools.invalid("superseded_by_job_id must reference an accessible Job in the current repository") unless superseding_job
        end

        unless insight.retire!(
          reason: reason_s,
          actor: run,
          superseded_by_insight: superseding_insight,
          superseded_by_job: superseding_job,
          retire_accepted: !!retire_accepted
        )
          return Mcp::Tools.invalid("InsightSuggestion ##{insight.id} could not be retired (state changed concurrently).")
        end

        append_workflow_artifact(run, insight)
        Mcp::Tools.write_log(run, "[mcp] retire_insight: ##{insight.id} #{insight.title.truncate(80)}")

        MCP::Tool::Response.new([
          { type: "text", text: "InsightSuggestion ##{insight.id} retired." }
        ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::RetireInsightTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def visible_insight(insight_id, run)
        id = Integer(insight_id, exception: false)
        return unless id

        InsightSuggestion.for_repository(run.job.repository).find_by(id: id)
      end

      def visible_job(job_id, run)
        id = Integer(job_id, exception: false)
        return unless id

        Job.find_by(id: id, repository_id: run.job.repository_id)
      end

      def append_workflow_artifact(run, insight)
        retirements = Array(run.workflow.artifact("insight_retirements"))
        retirements << {
          "id" => insight.id,
          "title" => insight.title,
          "reason" => insight.retired_reason,
          "superseded_by_insight_id" => insight.superseded_by_insight_id,
          "superseded_by_job_id" => insight.superseded_by_job_id
        }
        run.workflow.set_artifact!("insight_retirements", retirements)
      end
    end
  end
end
