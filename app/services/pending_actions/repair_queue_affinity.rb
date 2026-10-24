module PendingActions
  class RepairQueueAffinity < Base
    action_key "repair_queue_affinity"

    def perform
      job = repair_action_job
      run = target_run(job)
      progress!("Repairing queue affinity for #{run.slug}...")

      repair = repair_run!(run)
      @confirmation_outcome = repair[:outcome]

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
      errors.add(:payload, "job_id must be an integer") if payload["job_id"].present? && !Integer(payload["job_id"], exception: false)
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
      [
        payload["run_id"].presence&.then { |id| "Run: ##{id}" },
        payload["queue_name"].presence&.then { |queue| "Queue: #{queue}" }
      ].compact.join(", ").presence
    end

    repairs_job!

    attr_reader :confirmation_outcome

    private

    def target_run(job)
      job.runs.find(payload.fetch("run_id"))
    end

    def repair_run!(run)
      deleted_job_ids = SolidQueue::Job.transaction do
        queue_jobs = matching_solid_queue_jobs(run, lock: true)
        lock_queue_executions!(queue_jobs.map(&:id))
        claimed_job_ids = claimed_solid_queue_job_ids(queue_jobs.map(&:id))
        return { outcome: "skipped", run: run, claimed_solid_queue_job_ids: claimed_job_ids } if claimed_job_ids.any?

        ApplicationRecord.transaction do
          run.lock!
          run.reload
          return { outcome: "no_longer_eligible", run: run } unless repairable_run?(run)

          workflow = run.workflow
          workflow.lock!
          workflow.reload
          return { outcome: "no_longer_eligible", run: run } unless repairable_run?(run)
          validate_unsatisfied_affinity!(run, queue_jobs)

          workflow.update_columns(worker_hostname: nil, worker_storage_key: nil)
          set_in_memory_affinity!(workflow, hostname: nil, storage_key: nil)
        end

        delete_solid_queue_jobs!(queue_jobs.map(&:id))
      end

      run.reload
      return { outcome: "no_longer_eligible", run: run, deleted_solid_queue_job_ids: deleted_job_ids } unless repairable_run?(run)

      run.reenqueue!(ignore_workflow_affinity: true)
      run.workflow.update_columns(worker_hostname: nil, worker_storage_key: nil)

      { outcome: "applied", run: run, deleted_solid_queue_job_ids: deleted_job_ids }
    end

    def repairable_run?(run)
      run.queued? && (run.workflow&.queued? || run.workflow&.running?)
    end

    def validate_unsatisfied_affinity!(run, queue_jobs)
      decision = RunQueueResolver.resolve(run: run)
      if decision.sticky_resume
        queue = decision.details["sticky_resume_queue"] ? decision.queue_name : run.resume_worker_queue
        raise ArgumentError, "#{run.slug} still has a live worker satisfying its affinity on #{queue}."
      end

      dead_queue_jobs = queue_jobs.select do |job|
        explicit_worker_queue?(job.queue_name) && !InstanceVersion.worker_queue_live?(job.queue_name)
      end
      raise ArgumentError, "#{run.slug} has no dead explicit worker/storage queue to repair." if dead_queue_jobs.empty?

      replacement = RunQueueResolver.resolve(run: run, ignore_workflow_affinity: true)
      if replacement.blocked? || !InstanceVersion.worker_queue_live?(replacement.queue_name)
        raise ArgumentError, "#{run.slug} has no compatible live replacement capacity."
      end
    end

    def explicit_worker_queue?(queue_name)
      queue_name.to_s.start_with?("worker-", "resume-")
    end

    def matching_solid_queue_jobs(run, lock: false)
      scope = SolidQueue::Job
        .where(class_name: "RunJob", finished_at: nil)
      scope = scope.lock if lock
      SolidQueueRunJobQuery.matching(scope: scope, run_id: run.id)
    rescue NameError, ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[PendingActions::RepairQueueAffinity] Solid Queue tables unavailable: #{e.class}: #{e.message}")
      []
    end

    def lock_queue_executions!(job_ids)
      SolidQueue::ReadyExecution.where(job_id: job_ids).lock.load
      SolidQueue::ScheduledExecution.where(job_id: job_ids).lock.load
      SolidQueue::BlockedExecution.where(job_id: job_ids).lock.load
      SolidQueue::ClaimedExecution.where(job_id: job_ids).lock.load
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

    def set_in_memory_affinity!(workflow, hostname:, storage_key:)
      workflow.worker_hostname = hostname
      workflow.worker_storage_key = storage_key
      workflow.clear_attribute_changes([ :worker_hostname, :worker_storage_key ])
    end
  end
end
