module PendingActions
  class ForceLandingRecheck < Base
    action_key "force_landing_recheck"

    def perform
      job = repair_action_job
      result = LandingQueueRecheck.call(job) { |message| progress!(message) }
      refreshed = result.refreshed_state
      action.update!(payload: payload.merge("refreshed_state" => refreshed.deep_stringify_keys))
      audit!("forced landing recheck; blocker=#{refreshed[:landing_queue_blocked_reason].inspect}", run: job.current_run)
      nil
    end

    def execution_label
      "Refreshing landing state..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def presentation_label
      "Force landing recheck for #{presentation_job_slug}"
    end

    def presentation_detail
      members = (action.pending_action_group&.chat_pending_actions || [ action ]).sort_by(&:id)
      members.map { |member| presentation_line(member.payload.to_h) }.join("\n")
    end

    repairs_job!

    private

    def presentation_line(member_payload)
      observed = member_payload["observed_state"].to_h
      refreshed = member_payload["refreshed_state"].to_h
      parts = [
        "observed state: #{observed["state"].presence || "unknown"}",
        "observed blocker: #{blocker_key(member_payload["observed_blocker"])}"
      ]
      if refreshed.present?
        parts << "refreshed state: #{refreshed["state"].presence || "unknown"}"
        parts << "refreshed blocker: #{blocker_key(refreshed["landing_queue_blocked_reason"])}"
      end
      "- JOB-#{member_payload["job_id"]} — #{parts.join("; ")}"
    end

    def blocker_key(value)
      value.to_h["key"].presence || "none"
    end
  end
end
