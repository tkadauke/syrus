require "mcp"

module Mcp::Tools
  class ReplacePrBranchWithWorkflowOutputTool < MCP::Tool
    extend BranchDivergenceToolSupport

    tool_name "replace_pr_branch_with_workflow_output"
    description "Plan or request an audited destructive repair that force-pushes a branch-diverged workflow's output over the current PR branch with a lease. Admin/Supervisor only; confirmation required unless dry_run is true."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_id: { type: "integer", description: "Branch-diverged Workflow id." },
        reason: { type: "string", description: "Operator-facing audit reason for replacing the PR branch." },
        destructive_confirmation: { type: "string", description: "Must be exactly REPLACE PR BRANCH to create the pending action." },
        dry_run: { type: "boolean", description: "Return evidence without creating a pending action.", default: false }
      },
      required: %w[job_id workflow_id]
    )

    class << self
      def call(job_id:, workflow_id:, server_context:, reason: nil, destructive_confirmation: nil, dry_run: false)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job, _workflow, evidence, error = divergence_records(job_id, workflow_id)
        return error if error
        return Mcp::Tools.success(action: "replace_pr_branch_with_workflow_output", job_id: job.id, evidence: evidence, destructive_confirmation: "REPLACE PR BRANCH") if dry_run

        reason = reason.to_s.strip
        return structured_error("missing_reason", "reason is required") if reason.blank?
        unless destructive_confirmation.to_s == "REPLACE PR BRANCH"
          return structured_error(
            "missing_destructive_confirmation",
            "destructive_confirmation must be exactly REPLACE PR BRANCH",
            evidence: evidence
          )
        end

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "replace_pr_branch_with_workflow_output",
          payload: {
            "job_id" => job.id,
            "workflow_id" => Integer(workflow_id),
            "destructive_confirmation" => destructive_confirmation.to_s,
            "evidence" => evidence
          },
          reason: reason,
          message: evidence_message("Replace PR branch for #{job.slug} with workflow output?", evidence)
        )
      end
    end
  end
end
