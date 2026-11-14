require "mcp"

module Mcp::Tools
  class CancelJobTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "cancel_job"

    description <<~DESC
      Request cancellation of one or more Syrus Jobs in this repository. Pass
      Eligible states are
      #{Mcp::ControlToolContracts.states(JobCancellationEligibility::ELIGIBLE_STATES)};
      a closed Job is already terminal and must be reopened before further work.
      job_id for a single Job (unchanged single-confirmation behavior) or
      job_ids for multiple Jobs, which creates one grouped pending action the
      operator confirms or rejects together. The Job(s) are not cancelled
      until confirmation. The call creates only pending action(s); confirmation
      cancels active Runs/Workflows and closes each Job, without creating a Job,
      Workflow, or WorkUnit or entering admission control/the worker queue.
      A human-readable reason is required. For a single duplicate Job,
      canonical_job_id records its replacement in the same repository.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to cancel." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to cancel as one grouped pending action."
        },
        reason: { type: "string", minLength: 1, maxLength: 1_000, description: "Human-readable reason for cancellation." },
        canonical_job_id: { type: "integer", description: "Optional canonical replacement Job for duplicate work." }
      },
      required: %w[reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, reason:, canonical_job_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        context = McpToolContext.from_server_context(server_context)
        coworker_scope = context.allowed_repository_ids if context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        scope_payload = coworker_scope ? { "enforce_repository_scope" => true } : {}
        return Mcp::Tools.invalid("reason is required") if reason.to_s.strip.blank?
        return Mcp::Tools.invalid("reason is too long (maximum is 1000 characters)") if reason.to_s.length > 1_000
        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error
        return Mcp::Tools.invalid("canonical_job_id is only supported for one Job") if bulk && canonical_job_id.present?

        jobs = ids.map { |id| find_job!(id) }
        canonical_job = find_job!(canonical_job_id) if canonical_job_id.present?
        scoped_jobs = jobs + Array(canonical_job)
        if coworker_scope && scoped_jobs.any? { |job| !coworker_scope.include?(job.repository_id) }
          raise AuthorizationSupport::NotAccessible, "job not found or not accessible"
        end
        if canonical_job && (canonical_job == jobs.first || canonical_job.repository_id != jobs.first.repository_id)
          return Mcp::Tools.invalid("canonical_job_id must reference another accessible Job in the same repository")
        end
        ineligible = jobs.filter_map do |job|
          eligibility = JobCancellationEligibility.call(job: job)
          if job.landed_sha.present? || job.deployment_stage_statuses.exists?
            "#{job.slug}: landing or deployment evidence prevents cancellation"
          elsif !eligibility.eligible?
            "#{job.slug}: #{eligibility.message}"
          end
        end
        if ineligible.any?
          return invalid_job_states(
            "Cannot cancel #{ineligible.size} of #{jobs.size} Jobs - #{ineligible.join('; ')}",
            jobs
          )
        end

        unless bulk
          job = jobs.first
          pending_action = create_pending_action_for_current_message!(
            server_context,
            chat_session,
            action: "cancel_job",
            payload: {
              "job_id" => job.id, "reason" => reason.to_s.strip,
              "canonical_job_id" => canonical_job&.id
            }.compact.merge(scope_payload),
            requested_by: "agent",
            reason: reason.to_s.strip,
            subject: McpToolContext.from_server_context(server_context).agent_actor
          )

          return Mcp::Tools.success(
            pending_confirmation_id: pending_action.id,
            pending_action_id: pending_action.id,
            state: pending_action.state,
            message: "Cancel #{job.slug}? Cancellation requires operator confirmation."
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: jobs.map do |job|
            { action: "cancel_job", payload: {
                "job_id" => job.id, "reason" => reason.to_s.strip
              }.merge(scope_payload),
              requested_by: "agent", reason: reason.to_s.strip,
              subject: McpToolContext.from_server_context(server_context).agent_actor }
          end
        )
        bulk_action_response(group: group, message: "Cancel #{jobs.size} Jobs?")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def invalid_job_states(message, jobs)
        states = jobs.map { |job| { job_id: job.id, state: job.reload.state } }
        payload = { ok: false, error: message, jobs: states }
        payload.merge!(states.first) if states.one?
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ], error: true)
      end
    end
  end
end
