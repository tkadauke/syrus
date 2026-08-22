module PendingActions
  class ForceRebase < Base
    action_key "force_rebase"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      raise ArgumentError, "No PR on this Job to rebase." unless job.pr_number.present? || job.external_pr_number.present?
      raise ArgumentError, "No branch on this Job to rebase." if job.branch_name.blank?
      raise ArgumentError, "Terminal Jobs cannot be rebased." if job.closed? || job.no_change_needed?
      if RebaseWorkflowSelector.active_for_stack?(job)
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end
      if RebaseWorkflowSelector.active_merge_train_for_stack?(job)
        raise ArgumentError, "A merge train is already active for this stack — wait for it to finish."
      end

      progress!("Creating forced rebase workflow for #{job.slug}...")
      workflow = RebaseWorkflowSelector.instantiate(
        job: job,
        artifacts: {
          "repair_action" => "force_rebase",
          "repair_reason" => reason,
          "bypass_front_of_queue" => bypass_front_of_queue?
        }
      )
      progress!("Starting #{workflow.slug}...")
      WorkUnits::Launcher.start!(workflow)
      progress!("Recording repair audit...")
      audit!(job, workflow)
      workflow
    end

    def execution_label
      "Starting forced rebase..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def bypass_front_of_queue?
      payload.fetch("bypass_front_of_queue", true) != false
    end

    def audit!(job, workflow)
      run = job.current_run
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] forced #{workflow.trigger_kind} workflow ##{workflow.id}; bypass_front_of_queue=#{bypass_front_of_queue?}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
