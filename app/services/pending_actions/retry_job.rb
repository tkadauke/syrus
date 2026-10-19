module PendingActions
  class RetryJob < Base
    action_key "retry_job"

    def execute
      job = action_job
      mode = RetryJobs::Mode.for(payload.fetch("mode", "auto")).new(
        job: job, source_workflow_id: payload["source_workflow_id"], reason: payload["reason"]
      )
      progress!("Creating #{payload.fetch('mode', 'auto').humanize(capitalize: false)} retry for #{job.slug}...")
      result = mode.execute
      raise ArgumentError, result.error unless result.success?

      result.workflow
    end

    def execution_label
      "Creating retry workflow..."
    end

    def group_confirmation_strategy
      RetryJobs::Mode.for(payload.fetch("mode", "auto")).new(job: action_job).group_confirmation_strategy
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      mode = payload.fetch("mode", "auto")
      RetryJobs::Mode.for(mode)
      errors.add(:payload, "reason is required for refresh_base") if mode == "refresh_base" && payload["reason"].blank?
    rescue ArgumentError => e
      errors.add(:payload, e.message)
    end

    def action_detail
      "job_id: #{payload["job_id"]}, mode: #{payload.fetch('mode', 'auto')}"
    end

    def presentation_label
      label = "Retry #{presentation_job_slug} (#{payload.fetch('mode', 'auto').humanize})"
      details = payload["preflight"].to_h
      if details["checkpoint_sha"].present?
        "#{label}: checkpoint #{details['checkpoint_sha'].to_s.first(12)} onto #{details['base_ref']}"
      elsif details["failed_step_kind"].present?
        "#{label}: #{details['failed_step_kind']} in workflow #{details['source_workflow_id']}"
      elsif details["base_ref"].present?
        "#{label}: from #{details['base_ref']}"
      else
        label
      end
    end
  end
end
