module PendingActions
  class CancelStaleWork < Base
    action_key "cancel_stale_work"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      cancelled = cancel_work!(job)
      if payload.fetch("reconcile", true)
        WorkEngine::Reconciler.call(source: "operator:cancel_stale_work", job_id: job.id, execute_repairs: true)
      end
      audit!(job, cancelled)
      job.reload
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      workflow_ids.each do |workflow_id|
        errors.add(:payload, "workflow_ids must contain integers") unless Integer(workflow_id, exception: false)
      end
      run_ids.each do |run_id|
        errors.add(:payload, "run_ids must contain integers") unless Integer(run_id, exception: false)
      end
    end

    def action_detail
      "job_id: #{payload["job_id"]}, workflow_ids: #{workflow_ids.inspect}, run_ids: #{run_ids.inspect}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def cancel_work!(job)
      cancelled = { workflows: [], runs: [] }
      runs = target_runs(job)
      workflows = target_workflows(job)
      ApplicationRecord.transaction do
        runs.each do |run|
          next unless run.may_cancel?

          StateTransition.with_source("reconciler") do
            run.cancel!
            run.save!
          end
          cancelled[:runs] << run.id
        end

        workflows.each do |workflow|
          next unless workflow.may_cancel?

          StateTransition.with_source("reconciler") do
            workflow.artifacts = (workflow.artifacts || {}).merge(
              "cancelled_reason" => "operator_stale_work_repair",
              "cancelled_by_operator_repair_at" => Time.current.iso8601,
              "operator_repair_reason" => reason
            )
            workflow.cancel!
            workflow.save!
          end
          cancelled[:workflows] << workflow.id
        end
      end
      cancelled
    end

    def target_workflows(job)
      scope = job.workflows.active
      ids = workflow_ids.map { |id| Integer(id, exception: false) }.compact
      return scope.to_a if ids.empty?

      records = scope.where(id: ids).to_a
      missing = ids - records.map(&:id)
      raise ArgumentError, "Workflow ids are not active work for #{job.slug}: #{missing.join(", ")}" if missing.any?

      records
    end

    def target_runs(job)
      scope = job.runs.active
      ids = run_ids.map { |id| Integer(id, exception: false) }.compact
      return scope.to_a if ids.empty?

      records = scope.where(id: ids).to_a
      missing = ids - records.map(&:id)
      raise ArgumentError, "Run ids are not active work for #{job.slug}: #{missing.join(", ")}" if missing.any?

      records
    end

    def workflow_ids = Array(payload["workflow_ids"]).compact
    def run_ids = Array(payload["run_ids"]).compact

    def audit!(job, cancelled)
      run = job.runs.order(created_at: :desc, id: :desc).first
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] cancelled stale work workflows=#{cancelled[:workflows].inspect} runs=#{cancelled[:runs].inspect}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
