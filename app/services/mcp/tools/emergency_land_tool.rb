require "mcp"

module Mcp::Tools
  # Called by a Coding Mode chat agent only after the operator explicitly asks
  # for the emergency-land escape hatch in the current turn. Queues an operator
  # confirmation; the actual landing happens only after confirmation.
  class EmergencyLandTool < MCP::Tool
    extend JobLifecycleToolSupport
    extend ProposalToolSupport

    tool_name "emergency_land"

    description <<~DESC
      Skips Syrus's grader, adversarial-review, and visual-review pipeline
      entirely and lands the change by opening (if needed) and merging the PR.
      With job_id it lands an eligible, already-pushed Job branch; without
      job_id it captures the active clean, committed Coding Mode checkout into
      a new audit Job. This is an incident-response escape hatch, not a normal
      handoff path. Call it ONLY when the operator has explicitly and
      unambiguously asked for an emergency or urgent land in this turn, such as
      "emergency land this now" or "skip review and land". Never call this
      proactively -- not because graders are slow, not because tests are
      failing, and not because you inferred urgency yourself. If the operator
      has not said this explicitly in this turn, use complete_implement_step or
      submit_coding_changes instead.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Existing Syrus Job id. Omit to submit the active checkout directly." },
        repository_id: { type: "integer", description: "Repository for direct submission; defaults to the attached repository." },
        title: { type: "string", description: "Audit Job and PR title for direct submission." },
        description: { type: "string", description: "Short incident-change description for direct submission." },
        branch_name: {
          type: "string",
          description: "Existing Job branch (must match its recorded branch), or active checkout branch for direct submission."
        }
      },
      required: []
    )

    class << self
      def call(job_id: nil, repository_id: nil, title: nil, description: nil, branch_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = job_id.present? ? find_job(job_id) : [ nil, nil ]
        return error if error

        normalized_branch = GitBranchName.normalize(branch_name)
        repository = job&.repository || resolve_repository(chat_session, repository_id)
        validation_error = validate_request(chat_session: chat_session, job: job, repository: repository,
          branch_name: normalized_branch, title: title, description: description)
        return validation_error if validation_error

        existing_action = pending_landing_action_for(chat_session, job)
        if existing_action
          return pending_action_response(existing_action) if existing_action.action == "emergency_land"

          return Mcp::Tools.invalid("A complete_implement_step confirmation is already pending for #{job.slug}; resolve it before requesting emergency_land.")
        end

        payload = {
          "chat_session_id" => chat_session.id,
          "job_id" => job&.id,
          "repository_id" => repository.id,
          "branch_name" => normalized_branch.presence || job&.branch_name || current_checkout_branch(chat_session, repository),
          "title" => title.to_s.strip.presence,
          "description" => description.to_s.strip.presence
        }
        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "emergency_land",
          payload: payload,
          requested_by: "agent"
        )

        pending_action_response(pending_action)
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end

      private

      def find_job(job_id)
        normalized_id = Integer(job_id, exception: false)
        return [ nil, Mcp::Tools.invalid("job_id is required") ] unless normalized_id

        job = Job.find_by(id: normalized_id)
        return [ nil, Mcp::Tools.invalid("job not found: #{normalized_id}") ] unless job

        [ job, nil ]
      end

      def validate_request(chat_session:, job:, repository:, branch_name:, title:, description:)
        return Mcp::Tools.invalid("Emergency land is not enabled on this instance.") unless Feature.emergency_land_enabled?
        return Mcp::Tools.invalid("emergency_land is only available in Coding Mode chat sessions.") unless chat_session.coding?
        return Mcp::Tools.invalid("repository not found or not accessible") unless repository
        return Mcp::Tools.invalid("Emergency land requires repository admin permissions.") unless EmergencyLand::Permission.granted?(user: chat_session.user, repository: repository)
        return Mcp::Tools.invalid("branch_name is not a valid branch name.") if branch_name.present? && !GitBranchName.valid?(branch_name)
        if job
          return Mcp::Tools.invalid("branch_name is required because #{job.slug} has no recorded branch.") if job.branch_name.blank?
          return Mcp::Tools.invalid("branch_name must match #{job.slug}'s recorded branch #{job.branch_name}.") if branch_name.present? && branch_name != job.branch_name
          return Mcp::Tools.invalid("#{job.slug} is not eligible for emergency land from state #{job.state}.") unless EmergencyLand::Lander.eligible_state?(job)
        else
          return Mcp::Tools.invalid("title is required for direct emergency land") if title.to_s.strip.blank?
          return Mcp::Tools.invalid("description is required for direct emergency land") if description.to_s.strip.blank?
        end

        nil
      end

      def resolve_repository(chat_session, repository_id)
        repository_id.present? ? Repository.accessible_to(chat_session.user).active.find_by(id: repository_id) : chat_session.repository
      end

      def current_checkout_branch(chat_session, repository)
        ChatWorkspace.coding_checkout_snapshot(chat_session, repository)[:current_branch].presence
      rescue StandardError
        nil
      end

      def pending_landing_action_for(chat_session, job)
        chat_session.pending_actions
          .where(action: %w[complete_implement_step emergency_land])
          .where(state: %w[queued pending confirming failed])
          .detect { |action| job.nil? ? action.payload.to_h["job_id"].blank? : action.payload.to_h["job_id"].to_i == job.id }
      end

      def pending_action_response(pending_action)
        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Emergency land requires operator confirmation."
        )
      end
    end
  end
end
