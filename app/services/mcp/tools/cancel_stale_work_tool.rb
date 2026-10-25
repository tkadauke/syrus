require "mcp"

module Mcp::Tools
  class CancelStaleWorkTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    MAX_TARGETS = 100

    tool_name "cancel_stale_work"
    description <<~DESC
      Request cancellation of stale queued/running Workflows or Runs. Pass
      job_id for one Job with unchanged single-confirmation behavior, or pass
      targets for up to #{MAX_TARGETS} Jobs as one grouped pending action. A
      grouped call shares one root-cause reason and reconcile flag, validates
      every target before creating the group, and requires one operator
      confirmation for the whole batch.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id." },
        workflow_ids: { type: "array", items: { type: "integer" }, description: "Optional Workflow ids under this Job to cancel." },
        run_ids: { type: "array", items: { type: "integer" }, description: "Optional Run ids under this Job to cancel." },
        targets: {
          type: "array",
          minItems: 1,
          maxItems: MAX_TARGETS,
          items: {
            type: "object",
            properties: {
              job_id: { type: "integer", description: "Syrus Job id." },
              workflow_ids: { type: "array", items: { type: "integer" }, description: "Optional Workflow ids under this Job to cancel." },
              run_ids: { type: "array", items: { type: "integer" }, description: "Optional Run ids under this Job to cancel." },
              reconcile: { type: "boolean", description: "Run targeted reconciliation for this Job. Defaults to the top-level reconcile value." }
            },
            required: %w[job_id]
          },
          description: "One to 100 distinct Job targets to cancel as one grouped pending action. Mutually exclusive with job_id, workflow_ids, and run_ids."
        },
        reconcile: { type: "boolean", description: "Run targeted WorkEngine reconciliation after cancellation. Defaults to true." },
        reason: { type: "string", description: "Shared operator-facing root cause for the cancellation." }
      },
      required: %w[reason]
    )

    class << self
      def call(reason:, server_context:, job_id: nil, workflow_ids: nil, run_ids: nil, targets: nil, reconcile: true)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        if !targets.nil? && [ job_id, workflow_ids, run_ids ].any? { |value| !value.nil? }
          return Mcp::Tools.invalid("targets is mutually exclusive with job_id, workflow_ids, and run_ids")
        end

        return call_grouped(targets:, reconcile:, reason:, server_context:, chat_session:) unless targets.nil?

        job_id = integer_param(job_id, "job_id")
        return job_id if job_id.is_a?(MCP::Tool::Response)
        job = Job.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        eligibility = RepairPreflight.cancel_stale_work(job: job, workflow_ids: workflow_ids, run_ids: run_ids)
        return Mcp::Tools.invalid(eligibility.blocking_preconditions.join("; ")) unless eligibility.eligible?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "cancel_stale_work",
          payload: {
            "job_id" => job.id,
            "workflow_ids" => normalize_integer_list(workflow_ids),
            "run_ids" => normalize_integer_list(run_ids),
            "reconcile" => reconcile.nil? ? true : !!reconcile
          },
          reason: reason,
          message: "Cancel stale work for #{job.slug}?"
        )
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def call_grouped(targets:, reconcile:, reason:, server_context:, chat_session:)
        return Mcp::Tools.invalid("targets must be an array") unless targets.is_a?(Array)
        return Mcp::Tools.invalid("targets must not be empty") if targets.empty?
        return Mcp::Tools.invalid("targets may contain at most #{MAX_TARGETS} Jobs") if targets.size > MAX_TARGETS

        normalized_targets = targets.map.with_index do |target, index|
          return Mcp::Tools.invalid("targets[#{index}] must be an object") unless target.is_a?(Hash)

          attributes = target.to_h.with_indifferent_access
          target_job_id = Integer(attributes[:job_id], exception: false)
          return Mcp::Tools.invalid("targets[#{index}].job_id is required") unless target_job_id

          {
            job_id: target_job_id,
            workflow_ids: attributes[:workflow_ids],
            run_ids: attributes[:run_ids],
            reconcile: attributes.key?(:reconcile) ? attributes[:reconcile] != false : reconcile != false
          }
        end

        duplicate_ids = normalized_targets.map { |target| target[:job_id] }.tally.select { |_id, count| count > 1 }.keys
        return Mcp::Tools.invalid("duplicate job_id values in targets: #{duplicate_ids.join(', ')}") if duplicate_ids.any?

        jobs_by_id = Job.where(id: normalized_targets.map { |target| target[:job_id] }).index_by(&:id)
        missing_ids = normalized_targets.map { |target| target[:job_id] }.reject { |id| jobs_by_id.key?(id) }
        return Mcp::Tools.invalid("job not found: #{missing_ids.join(', ')}") if missing_ids.any?

        blockers = normalized_targets.filter_map do |target|
          job = jobs_by_id.fetch(target[:job_id])
          eligibility = RepairPreflight.cancel_stale_work(
            job: job,
            workflow_ids: target[:workflow_ids],
            run_ids: target[:run_ids]
          )
          "#{job.slug}: #{eligibility.blocking_preconditions.join('; ')}" unless eligibility.eligible?
        rescue ArgumentError => e
          "#{job.slug}: #{e.message}"
        end
        return Mcp::Tools.invalid(blockers.join(" | ")) if blockers.any?

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: normalized_targets.map do |target|
            {
              action: "cancel_stale_work",
              payload: {
                "job_id" => target[:job_id],
                "workflow_ids" => normalize_integer_list(target[:workflow_ids]),
                "run_ids" => normalize_integer_list(target[:run_ids]),
                "reconcile" => target[:reconcile]
              },
              requested_by: "agent",
              reason: reason
            }
          end,
          reason: reason
        )
        bulk_action_response(group: group, message: I18n.t("server.mcp.bulk_confirmation.cancel_stale_work", count: normalized_targets.size))
      end
    end
  end
end
