require "mcp"

module Mcp::Tools
  class AdoptCurrentPrHeadTool < MCP::Tool
    extend BranchDivergenceToolSupport

    tool_name "adopt_current_pr_head"
    description "Plan or request an audited repair that marks a branch-diverged workflow as superseded by the current PR head. Admin/Supervisor only; confirmation required unless dry_run is true."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_id: { type: "integer", description: "Branch-diverged Workflow id." },
        reason: { type: "string", description: "Operator-facing audit reason explaining why the current PR head already contains the desired outcome." },
        dry_run: { type: "boolean", description: "Return evidence without creating a pending action.", default: false }
      },
      required: %w[job_id workflow_id]
    )

    class << self
      def call(job_id:, workflow_id:, server_context:, reason: nil, dry_run: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job, _workflow, evidence, error = divergence_records(job_id, workflow_id)
        return error if error
        return Mcp::Tools.success(action: "adopt_current_pr_head", job_id: job.id, evidence: evidence) if dry_run

        reason = reason.to_s.strip
        return structured_error("missing_reason", "reason is required") if reason.blank?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "adopt_current_pr_head",
          payload: {
            "job_id" => job.id,
            "workflow_id" => Integer(workflow_id),
            "evidence" => evidence
          },
          reason: reason,
          message: evidence_message("Adopt current PR head for #{job.slug}?", evidence)
        )
      end
    end
  end
end
