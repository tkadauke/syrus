module PendingActions
  class OverrideLandingBlockerOnce < Base
    action_key "override_landing_blocker_once"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      blocker_key = payload.fetch("blocker_key").to_s
      refreshed_key = current_blocker_key(job)
      unless refreshed_key == blocker_key
        raise ArgumentError, "Current blocker is #{refreshed_key.presence || 'none'}, not #{blocker_key}."
      end
      unless LandingBlockerOverride.overridable?(blocker_key)
        raise ArgumentError, "#{blocker_key} cannot be bypassed by this tool."
      end
      if job.landing_blocker_override_key.present? && job.landing_blocker_override_used_at.blank?
        raise ArgumentError, "#{job.slug} already has an unused landing blocker override."
      end

      job.update!(
        landing_blocker_override_key: blocker_key,
        landing_blocker_override_reason: reason,
        landing_blocker_override_requested_at: Time.current,
        landing_blocker_override_requested_by_user_id: user.id,
        landing_blocker_override_used_at: nil
      )
      LandingQueueProcessorJob.perform_later
      audit!(job, blocker_key)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "blocker_key is required") if payload["blocker_key"].blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, blocker_key: #{payload["blocker_key"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def current_blocker_key(job)
      LandingQueueProcessor.refresh_snapshot!(Job.where(id: job.id))
      job.reload.landing_queue_blocked_reason.to_h["key"].to_s
    end

    def audit!(job, blocker_key)
      run = job.current_run
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] granted one-shot landing blocker override for #{blocker_key}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
