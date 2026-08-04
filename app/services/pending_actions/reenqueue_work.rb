module PendingActions
  class ReenqueueWork < Base
    action_key "reenqueue_work"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      record = reenqueue!(job)
      audit!(job, record)
      record
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      errors.add(:payload, "workflow_id must be an integer") if payload["workflow_id"].present? && !Integer(payload["workflow_id"], exception: false)
      errors.add(:payload, "run_id must be an integer") if payload["run_id"].present? && !Integer(payload["run_id"], exception: false)
    end

    def action_detail
      "job_id: #{payload["job_id"]}, workflow_id: #{payload["workflow_id"]}, run_id: #{payload["run_id"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def reenqueue!(job)
      run = target_run(job)
      return reenqueue_run!(run) if run

      workflow = target_workflow(job)
      raise ArgumentError, "workflow_id or run_id is required when the Job has no queued Run." unless workflow
      raise ArgumentError, "#{workflow.slug} is #{workflow.state}, not queued or running." unless workflow.queued? || workflow.running?

      queued_run = workflow.runs.where(state: "queued").order(created_at: :desc, id: :desc).first
      return reenqueue_run!(queued_run) if queued_run

      raise ArgumentError, "#{workflow.slug} is running but has no queued Run to re-enqueue." if workflow.running?
      raise ArgumentError, "#{workflow.slug} already has Runs." if workflow.runs.exists?

      first_step = workflow.first_step
      raise ArgumentError, "#{workflow.slug} has no first Step." unless first_step

      StepDispatcher.start_workflow(workflow).tap do |started_run|
        raise ArgumentError, "#{workflow.slug} remained blocked and did not start." unless started_run
      end
    end

    def reenqueue_run!(run)
      raise ArgumentError, "Run not found." unless run
      raise ArgumentError, "Run ##{run.id} is #{run.state}, not queued." unless run.queued?
      raise ArgumentError, "Workflow is not active for Run ##{run.id}." unless run.workflow&.queued? || run.workflow&.running?

      run.reenqueue!
      run
    end

    def target_run(job)
      if payload["run_id"].present?
        job.runs.find(payload["run_id"])
      else
        job.runs.where(state: "queued").order(created_at: :desc, id: :desc).first
      end
    end

    def target_workflow(job)
      if payload["workflow_id"].present?
        job.workflows.find(payload["workflow_id"])
      else
        job.workflows.active.order(created_at: :desc, id: :desc).first
      end
    end

    def audit!(job, record)
      run = record.is_a?(Run) ? record : job.runs.order(created_at: :desc, id: :desc).first
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] re-enqueued work via #{record.class.name}##{record.id}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
