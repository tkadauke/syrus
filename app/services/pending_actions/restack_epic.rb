module PendingActions
  class RestackEpic < Base
    action_key "restack_epic"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      epic = repair_action_epic
      plan = EpicRestackPlan.new(epic)
      actions = plan.actions
      raise ArgumentError, "No open child PR branches need restacking." if actions.empty?

      active_job = actions.map { |entry| Job.find(entry.fetch("job_id")) }.find do |job|
        RebaseWorkflowSelector.active_for_stack?(job)
      end
      if active_job
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end

      ApplicationRecord.transaction do
        actions.each do |entry|
          job = Job.find(entry.fetch("job_id"))
          parent = entry["target_parent_job_id"].present? ? Job.find(entry["target_parent_job_id"]) : nil
          job.update!(parent_job: parent)
        end
      end

      workflows = root_jobs(actions).map do |root|
        workflow = RebaseWorkflowSelector.instantiate(
          job: root,
          artifacts: {
            "repair_action" => "restack_epic",
            "repair_reason" => reason,
            "restack_plan" => plan.to_h
          },
          base_branch: root.effective_base_branch
        )
        StepDispatcher.start_workflow(workflow)
        workflow
      end
      audit!(epic, workflows, actions)
      workflows.first
    end

    def validate_payload(errors)
      errors.add(:payload, "epic_id is required") unless payload["epic_id"].present?
      errors.add(:payload, "strategy must be dependency_topology") if payload["strategy"].present? && payload["strategy"] != "dependency_topology"
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "epic_id: #{payload["epic_id"]}, strategy: #{payload["strategy"].presence || "dependency_topology"}"
    end

    def repair_action? = true
    def repair_snapshot_targets = repair_action_epic_or_nil&.work_jobs&.to_a || []

    private

    def repair_action_epic
      scope = user.admin? ? Epic.all : Epic.accessible_to(user)
      scope.find(payload.fetch("epic_id"))
    end

    def repair_action_epic_or_nil
      scope = user.admin? ? Epic.all : Epic.accessible_to(user)
      scope.find_by(id: payload["epic_id"])
    end

    def root_jobs(actions)
      root_ids = actions.select { |entry| entry["target_parent_job_id"].blank? }.map { |entry| entry.fetch("job_id") }
      Job.where(id: root_ids).order(:id).to_a
    end

    def audit!(epic, workflows, actions)
      run = workflows.first&.runs&.first
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] restacked #{epic.slug} with #{actions.size} branch(es) across #{workflows.size} rebase workflow(s); reason=#{reason}",
        kind: "system"
      )
    end
  end
end
