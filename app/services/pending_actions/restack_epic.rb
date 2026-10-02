require "set"

module PendingActions
  class RestackEpic < Base
    action_key "restack_epic"

    def perform
      epic = repair_action_epic
      progress!("Computing restack plan for #{epic.slug}...")
      plan = EpicRestackPlan.new(epic)
      actions = plan.actions
      if actions.empty?
        progress!("No open child PR branches need restacking; no workflows were launched and no metadata was changed.")
        action.update!(
          payload: payload.merge(
            "no_op" => true,
            "no_op_message" => "No open child PR branches need restacking; no workflows were launched and no metadata was changed."
          )
        )
        return nil
      end

      progress!("Checking for active epic-wide workflows...")
      action_jobs = actions.map { |entry| Job.find(entry.fetch("job_id")) }
      active_job = action_jobs.find do |job|
        RebaseWorkflowSelector.active_for_stack?(job)
      end
      if active_job
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end
      active_merge_train_job = action_jobs.find do |job|
        RebaseWorkflowSelector.active_merge_train_for_stack?(job)
      end
      if active_merge_train_job
        raise ArgumentError, "A merge train is already active for this stack — wait for it to finish."
      end

      progress!("Updating stack dependencies...")
      ApplicationRecord.transaction do
        actions.each do |entry|
          job = Job.find(entry.fetch("job_id"))
          parent = entry["target_parent_job_id"].present? ? Job.find(entry["target_parent_job_id"]) : nil
          job.update!(parent_job: parent)
        end
      end

      progress!("Creating rebase workflow(s)...")
      workflows = rebase_roots(actions).map do |root|
        workflow = RebaseWorkflowSelector.instantiate(
          job: root,
          artifacts: {
            "repair_action" => "restack_epic",
            "repair_reason" => reason,
            "restack_plan" => plan.to_h
          },
          base_branch: root.effective_base_branch
        )
        progress!("Starting #{workflow.slug}...")
        WorkUnits::Launcher.start!(workflow)
        workflow
      end
      progress!("Recording repair audit...")
      audit!(
        "restacked #{epic.slug} with #{actions.size} branch(es) across #{workflows.size} rebase workflow(s)",
        run: workflows.first&.runs&.first
      )
      workflows.first
    end

    def execution_label
      "Restacking epic branches..."
    end

    def validate_payload(errors)
      errors.add(:payload, "epic_id is required") unless payload["epic_id"].present?
      errors.add(:payload, "strategy must be dependency_topology") if payload["strategy"].present? && payload["strategy"] != "dependency_topology"
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      details = [
        "epic_id: #{payload["epic_id"]}",
        "strategy: #{payload["strategy"].presence || "dependency_topology"}"
      ]
      action_count = payload.dig("plan", "actions")&.size
      details << "planned_actionable_repairs: #{action_count}" if action_count
      details.join(", ")
    end

    def presentation_label
      "Restack Epic ##{payload["epic_id"]}"
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

    def rebase_roots(actions)
      action_ids = actions.map { |entry| entry.fetch("job_id") }.to_set
      root_ids = actions.filter_map do |entry|
        parent_id = entry["target_parent_job_id"]
        entry.fetch("job_id") if parent_id.blank? || !action_ids.include?(parent_id)
      end
      Job.where(id: root_ids).order(:id).to_a
    end
  end
end
