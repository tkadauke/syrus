require "mcp"

module SyrusChatMcp
  class RetryFromCurrentPrBranchTool < MCP::Tool
    extend BranchDivergenceToolSupport

    tool_name "retry_from_current_pr_branch"
    description "Plan or request an audited manual agentic repair run based on the current remote PR branch instead of stale branch-diverged workflow output. Admin/Supervisor only; confirmation required unless dry_run is true."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_id: { type: "integer", description: "Branch-diverged Workflow id." },
        instructions: { type: "string", description: "Optional focused repair instructions. A branch-divergence repair prompt is used when omitted." },
        reason: { type: "string", description: "Operator-facing audit reason for retrying from the current PR branch." },
        dry_run: { type: "boolean", description: "Return evidence without creating a pending action.", default: false }
      },
      required: %w[job_id workflow_id]
    )

    class << self
      def call(job_id:, workflow_id:, server_context:, instructions: nil, reason: nil, dry_run: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job, _workflow, evidence, error = divergence_records(job_id, workflow_id)
        return error if error
        return SyrusChatMcp.success(action: "retry_from_current_pr_branch", job_id: job.id, evidence: evidence) if dry_run

        reason = reason.to_s.strip
        return structured_error("missing_reason", "reason is required") if reason.blank?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "retry_from_current_pr_branch",
          payload: {
            "job_id" => job.id,
            "workflow_id" => Integer(workflow_id),
            "instructions" => instructions.to_s.strip.presence,
            "evidence" => evidence
          }.compact,
          reason: reason,
          message: evidence_message("Retry #{job.slug} from the current PR branch?", evidence)
        )
      end
    end
  end
end
