class RebaseAttemptGuard
  ATTEMPT_CAP = 5
  BLOCK_REASON = "rebase cap reached; manual rebase or PR update required".freeze
  AGENT_REBASE_STEPS = %w[ agent_rebase stack_agent_rebase ].freeze

  def self.cap_reached?(job, pr: nil)
    consecutive_failures(job, pr: pr) >= ATTEMPT_CAP
  end

  def self.cooling_down?(job, pr: nil)
    cooldown = AppSetting.rebase_failure_cooldown_minutes.minutes
    return false unless cooldown.positive?

    recent_failed_agent_workflow(job, pr: pr, since: cooldown.ago).present?
  end

  def self.blocking_landing?(job)
    job.pr_mergeable == false && cap_reached?(job)
  end

  def self.consecutive_failures(job, pr: nil)
    consecutive = 0
    job.workflows.where(trigger_kind: RebaseWorkflowSelector::TRIGGER_KINDS).reorder(id: :desc).each do |workflow|
      break if workflow.succeeded?
      next unless workflow.failed?

      break if pr && !matches_pr?(workflow, job, pr)

      consecutive += 1
    end
    consecutive
  end

  def self.result_for(workflow, job)
    stack_entry = Array(workflow.artifact(StackRebasePlan::RESULTS_ARTIFACT)).find do |entry|
      entry["job_id"].to_i == job.id
    end
    stack_entry&.fetch("result", nil) || workflow.artifact("auto_rebase_result")
  end

  def self.branch_for(workflow, job)
    stack_entry = Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT)).find do |entry|
      entry["job_id"].to_i == job.id
    end
    stack_entry&.fetch("branch_name", nil).presence || workflow.artifact(RebaseTarget::BRANCH_ARTIFACT).presence
  end

  def self.recent_failed_agent_workflow(job, pr:, since:)
    job.workflows
       .where(trigger_kind: RebaseWorkflowSelector::TRIGGER_KINDS, state: "failed")
       .where("COALESCE(finished_at, updated_at) >= ?", since)
       .reorder(id: :desc)
       .detect do |workflow|
         failed_in_agent_rebase?(workflow) && matches_pr?(workflow, job, pr)
       end
  end
  private_class_method :recent_failed_agent_workflow

  def self.failed_in_agent_rebase?(workflow)
    workflow.steps.where(kind: AGENT_REBASE_STEPS, state: "failed").exists?
  end
  private_class_method :failed_in_agent_rebase?

  def self.matches_pr?(workflow, job, pr)
    result = result_for(workflow, job)
    return true unless result.is_a?(Hash)
    return true unless pr

    branch_name = branch_for(workflow, job)
    head_sha = pr_head_sha(pr)
    base_sha = pr_base_sha(pr)
    pre_sha = result["pre_sha"].presence
    result_base_sha = result["base_sha"].presence

    return false if branch_name.present? && job.branch_name.present? && branch_name != job.branch_name
    return false if head_sha.present? && pre_sha.present? && head_sha != pre_sha
    return false if base_sha.present? && result_base_sha.present? && base_sha != result_base_sha

    true
  end
  private_class_method :matches_pr?

  def self.pr_head_sha(pr)
    pr.head&.sha.to_s.presence
  end
  private_class_method :pr_head_sha

  def self.pr_base_sha(pr)
    pr.base&.sha.to_s.presence
  end
  private_class_method :pr_base_sha
end
