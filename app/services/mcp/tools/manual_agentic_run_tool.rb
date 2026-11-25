require "mcp"

module Mcp::Tools
  class ManualAgenticRunTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "manual_agentic_run"
    description "Request an operator-confirmed one-off Job-scoped agentic repair workflow with precise instructions. Deterministic repair tools are preferred; authenticated GitHub access is an explicit break-glass last resort."

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
        failed_workflow_id: { type: "integer", description: "Optional failed Workflow id when base is failed_workflow_workspace." },
        github_access: { type: "boolean", description: "Request separately confirmed, Run-scoped authenticated GitHub access. Defaults to false." },
        destructive_github_operations: { type: "boolean", description: "Separately declare destructive GitHub operations. Rejected unless github_access is true." },
        expected_outcomes: {
          type: "object",
          description: "Required provider-verifiable remote outcomes for break-glass access.",
          properties: {
            remote_branch: { type: "object", properties: { name: { type: "string" }, sha: { type: "string", description: "Exact expected SHA, or local_head to require the published implementation HEAD." } }, required: %w[name sha] },
            pull_request: { type: "object", properties: { number: { type: "integer" }, base: { type: "string" }, state: { type: "string" }, labels: { type: "array", items: { type: "string" } }, comment_contains: { type: "string" } } }
          }
        }
      },
      required: %w[job_id base instructions reason]
    )

    class << self
      def call(job_id:, base:, instructions:, reason:, server_context:, push: true, failed_workflow_id: nil,
               github_access: false, destructive_github_operations: false, expected_outcomes: nil)
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
        if destructive_github_operations && !github_access
          return structured_error("destructive_access_requires_github_access", "destructive GitHub operations require break-glass GitHub access.")
        end
        if github_access && expected_outcomes.to_h.blank?
          return structured_error("missing_expected_outcomes", "break-glass GitHub access requires provider-verifiable expected_outcomes.")
        end
        if github_access && (!job.repository.installation&.active? || !job.repository.installation.covers_repository?(job.repository))
          return structured_error("scoped_credential_unavailable", "break-glass GitHub access requires an active installation covering this repository.")
        end

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
            "failed_workflow_id" => failed_workflow_id,
            "github_access" => github_access == true,
            "destructive_github_operations" => destructive_github_operations == true,
            "expected_outcomes" => expected_outcomes.to_h.deep_stringify_keys
          }.compact,
          reason: reason,
          message: confirmation_message(job, base_result, push, github_access, destructive_github_operations)
        )
      end

      private

      def confirmation_message(job, base_result, push, github_access, destructive)
        base = "Start a manual agentic run for #{job.slug} from #{base_result.message}; push=#{push != false}?"
        return base unless github_access

        app_slug = AppSetting.current.github_app_slug.to_s.delete_suffix("[bot]").presence
        identity = [ ("#{app_slug}[bot]" if app_slug), "installation on #{job.repository.installation.account_login}" ].compact.join("; ")
        "#{base} BREAK-GLASS: grant credential use plus external write to #{job.repository.slug} as #{identity}, " \
          "scoped to contents/pull requests/issues; commands are audited and declared outcomes are provider-verified" \
          "#{destructive ? '; destructive GitHub operations are also requested' : '; destructive operations remain unavailable'}."
      end

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
