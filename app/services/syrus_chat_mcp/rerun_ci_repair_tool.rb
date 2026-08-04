require "mcp"

module SyrusChatMcp
  class RerunCiRepairTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "rerun_ci_repair"
    description "Plan an audited manual CI repair workflow for the current PR head, even when last_ci_handled_sha already matches. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        reason: { type: "string", description: "Operator-facing audit reason for rerunning CI repair." },
        clear_handled_sha: { type: "boolean", description: "Clear last_ci_handled_sha before dispatch when it matches the current PR head.", default: true },
        instructions: { type: "string", description: "Optional custom instructions added to the CI repair agent prompt." },
        override_repeated_sha: { type: "boolean", description: "Allow another CI repair when this SHA already has repeated ci_failure workflows.", default: false },
        agent_provider: { type: "string", description: "Optional agent provider override for this repair workflow." }
      },
      required: %w[job_id reason]
    )

    class << self
      def call(job_id:, reason:, clear_handled_sha: true, instructions: nil, override_repeated_sha: false, agent_provider: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        job = find_admin_job(job_id)
        return job if job.is_a?(MCP::Tool::Response)

        reason = reason.to_s.strip
        return SyrusChatMcp.invalid("reason is required") if reason.empty?

        refresh = CiRepair::CheckRefresh.call(job)
        return SyrusChatMcp.invalid("Current PR checks are #{refresh.state}; no failing checks are available for a CI repair rerun.") unless refresh.state == "failing"

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "rerun_ci_repair",
          payload: {
            "job_id" => job.id,
            "clear_handled_sha" => clear_handled_sha != false,
            "instructions" => instructions.to_s.strip.presence,
            "override_repeated_sha" => override_repeated_sha == true,
            "agent_provider" => agent_provider.to_s.strip.presence,
            "observed_head_sha" => refresh.head_sha,
            "observed_failed_checks" => refresh.failed_check_summaries
          }.compact,
          reason: reason,
          message: "Rerun CI repair for #{job.slug} at #{refresh.head_sha[0, 12]}? Failing checks: #{check_labels(refresh)}."
        )
      rescue ArgumentError => e
        SyrusChatMcp.invalid(e.message)
      end

      private

      def find_admin_job(job_id)
        integer = integer_param(job_id, "job_id")
        return integer if integer.is_a?(MCP::Tool::Response)

        Job.find_by(id: integer) || SyrusChatMcp.invalid("job not found: #{integer}")
      end

      def check_labels(refresh)
        labels = refresh.failed_check_summaries.map do |check|
          name = check[:name].presence || "unknown"
          url = check[:details_url].presence
          url ? "#{name} (#{url})" : name
        end
        labels.presence&.join(", ") || "unknown"
      end
    end
  end
end
