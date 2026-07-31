require "mcp"

module SyrusChatMcp
  class ManualAgenticRunTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "manual_agentic_run"
    description "Request an operator-confirmed one-off Job-scoped agentic repair workflow with precise instructions."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to repair." },
        base: {
          type: "string",
          enum: ManualAgenticRun::BaseSelection::VALUES,
          description: "Workspace base for the repair run."
        },
        instructions: { type: "string", description: "Precise instructions for the agentic repair run." },
        reason: { type: "string", description: "Operator-facing audit reason for starting the run." },
        push: { type: "boolean", description: "Whether successful changes should be pushed to the existing PR branch. Defaults to true." },
        failed_workflow_id: { type: "integer", description: "Optional failed Workflow id when base is failed_workflow_workspace." }
      },
      required: %w[job_id base instructions reason]
    )

    class << self
      def call(job_id:, base:, instructions:, reason:, server_context:, push: true, failed_workflow_id: nil)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return structured_error("job_not_found", "job not found: #{job_id}") unless job

        reason = reason.to_s.strip
        instructions = instructions.to_s.strip
        return structured_error("missing_reason", "reason is required") if reason.blank?
        return structured_error("missing_instructions", "instructions are required") if instructions.blank?

        base_result = ManualAgenticRun::BaseSelection.for(base).new(
          job: job,
          payload: { "failed_workflow_id" => failed_workflow_id }.compact
        ).resolve
        return structured_base_error(base_result) unless base_result.success?
        if push != false && base.to_s == "fresh_checkout"
          return structured_error(
            "fresh_checkout_push_not_supported",
            "fresh_checkout cannot push to the existing PR branch; use current_pr_branch or set push=false.",
            valid_bases: ManualAgenticRun::BaseSelection::VALUES
          )
        end
        if push != false && job.branch_name.blank?
          return structured_error("missing_pr_branch", "push requires an existing PR branch.")
        end
        if push != false && (job.pr_number.presence || job.external_pr_number.presence).blank?
          return structured_error("missing_pr", "push requires an existing PR.")
        end

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "manual_agentic_run",
          payload: {
            "job_id" => job.id,
            "base" => base.to_s,
            "instructions" => instructions,
            "push" => push != false,
            "failed_workflow_id" => failed_workflow_id
          }.compact,
          reason: reason,
          message: "Start a manual agentic run for #{job.slug} from #{base_result.message}; push=#{push != false}?"
        )
      end

      private

      def structured_base_error(result)
        structured_error(result.error, result.message, valid_bases: result.valid_bases)
      end

      def structured_error(code, message, extra = {})
        MCP::Tool::Response.new(
          [ { type: "text", text: JSON.generate({ error: code, message: message }.merge(extra)) } ],
          error: true
        )
      end
    end
  end
end
