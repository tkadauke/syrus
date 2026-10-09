module PendingActions
  class RepairQueueAffinity < Base
    action_key "repair_queue_affinity"

    def perform
      job = repair_action_job
      run = target_run(job)
      progress!("Repairing queue affinity for #{run.slug}...")

      repair = repair_run!(run)

      progress!("Recording repair audit...")
      audit!(
        "repaired queue affinity for #{run.slug}; deleted_solid_queue_jobs=#{repair[:deleted_solid_queue_job_ids].inspect}",
        run: run
      )
      run.reload
    end

    def execution_label
      "Repairing queue affinity..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "run_id is required") unless payload["run_id"].present?
      errors.add(:payload, "run_id must be an integer") if payload["run_id"].present? && !Integer(payload["run_id"], exception: false)
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, run_id: #{payload["run_id"]}"
    end

    def presentation_label
      "Repair queue affinity for #{presentation_job_slug}"
    end

    def presentation_detail
      payload["run_id"].presence&.then { |id| "Run: ##{id}" }
    end

    repairs_job!

    private

    def target_run(job)
      job.runs.find(payload.fetch("run_id"))
    end

    def repair_run!(run)
      deleted_job_ids = []

      ApplicationRecord.transaction do
        run.lock!
        run.reload
        validate_repairable_run!(run)

        workflow = run.workflow
        workflow.lock!
        workflow.reload
        validate_repairable_run!(run)
        validate_unsatisfied_affinity!(run, workflow)

        queue_jobs = matching_solid_queue_jobs(run)
        claimed_job_ids = claimed_solid_queue_job_ids(queue_jobs.map(&:id))
        if claimed_job_ids.any?
          raise ArgumentError, "#{run.slug} already has claimed Solid Queue jobs: #{claimed_job_ids.join(", ")}."
        end

        deleted_job_ids = delete_solid_queue_jobs!(queue_jobs.map(&:id))
        workflow.update_columns(worker_hostname: nil, worker_storage_key: nil)
        set_in_memory_affinity!(workflow, hostname: nil, storage_key: nil)
        run.reenqueue!(ignore_workflow_affinity: true)
        workflow.update_columns(worker_hostname: nil, worker_storage_key: nil)
        set_in_memory_affinity!(workflow, hostname: nil, storage_key: nil)
      end

      { deleted_solid_queue_job_ids: deleted_job_ids }
    end

    def validate_repairable_run!(run)
      raise ArgumentError, "#{run.slug} is #{run.state}, not queued." unless run.queued?
      raise ArgumentError, "Workflow is not active for #{run.slug}." unless run.workflow&.queued? || run.workflow&.running?
    end

    def validate_unsatisfied_affinity!(run, workflow)
      unless workflow.worker_storage_key.present? || workflow.worker_hostname.present?
        raise ArgumentError, "#{run.slug} has no worker affinity to repair."
      end

      decision = RunQueueResolver.resolve(run: run)
      return unless decision.sticky_resume

      queue = decision.details["sticky_resume_queue"] ? decision.queue_name : run.resume_worker_queue
      raise ArgumentError, "#{run.slug} still has a live worker satisfying its affinity on #{queue}."
    end

    def matching_solid_queue_jobs(run)
      SolidQueue::Job
        .where(class_name: "RunJob", finished_at: nil)
        .where("arguments LIKE ?", "%#{run.id}%")
        .lock
        .to_a
        .select { |job| active_job_arguments(job.arguments).first.to_i == run.id }
    rescue NameError, ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[PendingActions::RepairQueueAffinity] Solid Queue tables unavailable: #{e.class}: #{e.message}")
      []
    end

    def claimed_solid_queue_job_ids(job_ids)
      return [] if job_ids.empty?

      SolidQueue::ClaimedExecution.where(job_id: job_ids).pluck(:job_id)
    end

    def delete_solid_queue_jobs!(job_ids)
      job_ids = Array(job_ids).map(&:to_i).select(&:positive?)
      return [] if job_ids.empty?

      SolidQueue::ReadyExecution.where(job_id: job_ids).delete_all if defined?(SolidQueue::ReadyExecution)
      SolidQueue::ScheduledExecution.where(job_id: job_ids).delete_all if defined?(SolidQueue::ScheduledExecution)
      SolidQueue::BlockedExecution.where(job_id: job_ids).delete_all if defined?(SolidQueue::BlockedExecution)
      SolidQueue::FailedExecution.where(job_id: job_ids).delete_all if defined?(SolidQueue::FailedExecution)
      SolidQueue::Job.where(id: job_ids).delete_all
      job_ids
    end

    def active_job_arguments(arguments)
      payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
      args = payload.is_a?(Hash) ? (payload["arguments"] || payload[:arguments]) : payload
      args.is_a?(Array) ? args : []
    rescue JSON::ParserError, TypeError
      []
    end

    def set_in_memory_affinity!(workflow, hostname:, storage_key:)
      workflow.worker_hostname = hostname
      workflow.worker_storage_key = storage_key
      workflow.clear_attribute_changes([ :worker_hostname, :worker_storage_key ])
    end
  end
end
