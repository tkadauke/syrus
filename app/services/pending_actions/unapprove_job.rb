module PendingActions
  class UnapproveJob < Base
    action_key "unapprove_job"

    def execute
      job = action_permitted_job
      raise ArgumentError, "job must be in approved state" unless job.approved?

      progress!("Unapproving #{job.slug}...")
      Job::ApprovalUnapprover.call(job: job, user: user)
      job
    end

    def execution_label
      "Unapproving job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def presentation_label
      "Unapprove #{presentation_job_slug}"
    end

    def tool_card_outcome
      group = action.pending_action_group
      return unless group

      members = group.chat_pending_actions.sort_by(&:id)
      succeeded_job_ids = job_ids_for(members.select(&:confirmed?))
      failed_members = members.select(&:failed?)
      failed_job_ids = job_ids_for(failed_members)
      status = group_outcome_status(group, succeeded_job_ids:, failed_job_ids:)

      {
        status: status,
        succeeded_job_ids: succeeded_job_ids,
        failed_job_ids: failed_job_ids,
        previous_state: succeeded_job_ids.size == members.size ? "approved" : nil,
        new_state: succeeded_job_ids.size == members.size ? "implemented" : nil,
        message: group_outcome_message(members.size, succeeded_job_ids, failed_members)
      }.compact
    end

    private

    def job_ids_for(members)
      members.filter_map { |member| member.payload["job_id"] }
    end

    def group_outcome_status(group, succeeded_job_ids:, failed_job_ids:)
      return "partial_failure" if succeeded_job_ids.any? && failed_job_ids.any?
      return "failed" if failed_job_ids.any?

      group.state
    end

    def group_outcome_message(member_count, succeeded_job_ids, failed_members)
      return unless failed_members.any? || succeeded_job_ids.size == member_count
      return "Unapproved #{member_count} Jobs." if failed_members.empty?

      failures = failed_members.map do |member|
        "JOB-#{member.payload['job_id']}: #{member.execution_error.presence || 'failed'}"
      end
      "Unapproved #{succeeded_job_ids.size} of #{member_count} Jobs; #{failures.join(', ')}"
    end

    def action_permitted_job
      (user.admin? ? Job.all : user.jobs).find(payload.fetch("job_id"))
    end
  end
end
