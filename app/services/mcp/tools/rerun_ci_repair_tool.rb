require "mcp"

module Mcp::Tools
  class RerunCiRepairTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "rerun_ci_repair"
    description "Plan an audited manual CI repair workflow for the current PR head, even when last_ci_handled_sha already matches. Requires operator confirmation."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        job_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Jobs sharing one rerun policy, provider, instructions, and reason." },
        reason: { type: "string", description: "Operator-facing audit reason for rerunning CI repair." },
        clear_handled_sha: { type: "boolean", description: "Clear last_ci_handled_sha before dispatch when it matches the current PR head.", default: true },
        instructions: { type: "string", description: "Optional custom instructions added to the CI repair agent prompt." },
        override_repeated_sha: { type: "boolean", description: "Allow another CI repair when this SHA already has repeated ci_failure workflows.", default: false },
        agent_provider: { type: "string", description: "Optional agent provider override for this repair workflow." }
      },
      required: %w[reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, reason:, clear_handled_sha: true, instructions: nil, override_repeated_sha: false, agent_provider: nil, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error
        jobs = ids.map { |id| Job.find_by(id: id) }
        missing = ids.zip(jobs).filter_map { |id, job| id unless job }
        return Mcp::Tools.invalid("job not found: #{missing.join(', ')}") if missing.any?

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        refreshes = jobs.map { |job| CiRepair::CheckRefresh.call(job) }
        invalid_refreshes = jobs.zip(refreshes).filter_map { |job, refresh| "#{job.slug}: checks are #{refresh.state}" unless refresh.state == "failing" }
        return Mcp::Tools.invalid(invalid_refreshes.join(" | ")) if invalid_refreshes.any?
        eligibilities = jobs.map { |job| RepairPreflight.ci_repair(job: job) }
        blocked = jobs.zip(eligibilities).filter_map { |job, eligibility| "#{job.slug}: #{eligibility.blocking_preconditions.join('; ')}" unless eligibility.eligible? }
        return Mcp::Tools.invalid(blocked.join(" | ")) if blocked.any?

        attributes = jobs.zip(refreshes).map { |job, refresh| {
          action: "rerun_ci_repair", payload: {
            "job_id" => job.id, "clear_handled_sha" => clear_handled_sha != false,
            "instructions" => instructions.to_s.strip.presence, "override_repeated_sha" => override_repeated_sha == true,
            "agent_provider" => agent_provider.to_s.strip.presence, "observed_head_sha" => refresh.head_sha,
            "observed_failed_checks" => refresh.failed_check_summaries
          }.compact, requested_by: "agent", reason: reason
        } }
        unless bulk
          job = jobs.first
          refresh = refreshes.first
          return create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "rerun_ci_repair",
          payload: attributes.first[:payload],
          reason: reason,
          message: "Rerun CI repair for #{job.slug} at #{refresh.head_sha[0, 12]}? Failing checks: #{check_labels(refresh)}."
          )
        end
        group = create_pending_action_group!(server_context:, chat_session:, reason:, member_attributes: attributes)
        bulk_action_response(group:, message: "Rerun CI repair for #{jobs.size} Jobs?")
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def find_admin_job(job_id)
        integer = integer_param(job_id, "job_id")
        return integer if integer.is_a?(MCP::Tool::Response)

        Job.find_by(id: integer) || Mcp::Tools.invalid("job not found: #{integer}")
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
