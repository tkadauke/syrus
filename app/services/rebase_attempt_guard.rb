class RebaseAttemptGuard
  extend RebaseResultLookup

  ATTEMPT_CAP = 3
  ATTEMPT_TRIGGER_KINDS = [ *RebaseWorkflowSelector::TRIGGER_KINDS, "base_refresh_retry" ].freeze
  BLOCK_REASON = "rebase retry blocked after repeated failures; manual rebase or a PR update is required (cooldown expiry alone won't help if the failure wasn't transient)".freeze
  AGENT_REBASE_STEPS = %w[ agent_rebase stack_agent_rebase ].freeze
  MEMORY_WRITE_RETRY_STORM_THRESHOLD = 2

  def self.cap_reached?(job, pr: nil)
    return true if permanently_blocked_by_provider_configuration?(job)

    workflows = consecutive_failed_agent_rebase_workflows(job, pr: pr)
    return true if permanently_blocked_by?(workflows)
    return false unless workflows.size >= ATTEMPT_CAP

    cooldown = AppSetting.rebase_failure_cooldown_minutes.minutes
    return false unless cooldown.positive?

    recent_failed_agent_workflow(job, pr: pr, since: cooldown.ago).present?
  end

  # True when retrying cannot help, as distinct from `cooling_down?`, where
  # waiting might.
  #
  # The difference matters to callers that legitimately bypass the time-based
  # cooldown because something in the world actually changed -- main health
  # recovering, say, which gives a red PR a new base worth re-checking. That
  # reasoning holds for a transient failure and collapses for a deterministic
  # one: a `force_push` refusing to publish a branch missing its latest
  # handoff fix fails identically no matter how many times the base moves, so
  # a sweep that ignores every guard turns one broken branch into an agent run
  # every few minutes for days.
  def self.permanently_blocked?(job, pr: nil)
    return true if permanently_blocked_by_provider_configuration?(job)

    permanently_blocked_by?(consecutive_failed_agent_rebase_workflows(job, pr: pr))
  end

  def self.cooling_down?(job, pr: nil)
    return true if permanently_blocked_by_provider_configuration?(job)

    return true if permanently_blocked_by?(consecutive_failed_agent_rebase_workflows(job, pr: pr))

    cooldown = AppSetting.rebase_failure_cooldown_minutes.minutes
    return false unless cooldown.positive?

    recent_failed_agent_workflow(job, pr: pr, since: cooldown.ago).present?
  end

  # A time-based cooldown assumes the next attempt has a chance of
  # succeeding once enough wall-clock time has passed. That's true for a
  # transient failure (a dead worker, a rate limit) but not for one
  # RunFailureClassifier already determined is permanent (e.g. a missing
  # agent provider credential) -- nothing about the workflow's inputs
  # changes between attempts, so every cooldown-expiry retry fails the
  # same way, forever, at the cooldown cadence. Block indefinitely on the
  # same PR head/base instead; `matches_pr?` already lifts the block the
  # moment the PR actually changes (a new push, a rebased base).
  def self.permanently_blocked_by?(consecutive_workflows)
    latest = consecutive_workflows.first
    return false unless latest

    run = latest_failed_agent_rebase_run(latest) || latest_failed_run(latest)
    run&.run_failure_classification&.retryable == false
  end
  private_class_method :permanently_blocked_by?

  def self.permanently_blocked_by_provider_configuration?(job)
    workflow = job.workflows
      .where(trigger_kind: ATTEMPT_TRIGGER_KINDS)
      .reorder(id: :desc)
      .first
    return false unless workflow&.failed? && failed_in_agent_rebase?(workflow)

    classification = latest_failed_agent_rebase_run(workflow)&.run_failure_classification

    classification&.classification == "provider_auth_or_config" && classification.retryable == false
  end
  private_class_method :permanently_blocked_by_provider_configuration?

  def self.latest_failed_agent_rebase_run(workflow)
    workflow.steps
      .where(kind: AGENT_REBASE_STEPS, state: "failed")
      .order(id: :desc)
      .first
      &.runs
      &.order(id: :desc)
      &.first
  end
  private_class_method :latest_failed_agent_rebase_run

  def self.blocking_landing?(job)
    job.pr_mergeable == false && cap_reached?(job)
  end

  def self.consecutive_failures(job, pr: nil)
    consecutive_failed_agent_rebase_workflows(job, pr: pr).size
  end

  # Shared scan behind `consecutive_failures` and `permanently_blocked_by?`:
  # the most recent run of failed agent-rebase workflows for this Job (and,
  # when `pr:` is given, matching its current head/base), most-recent first.
  # Walks back from the latest workflow and stops at the first success, the
  # first workflow that didn't fail in the agent-rebase step, or the first
  # one that no longer matches the PR.
  def self.consecutive_failed_agent_rebase_workflows(job, pr: nil)
    workflows = []
    job.workflows.where(trigger_kind: ATTEMPT_TRIGGER_KINDS).reorder(id: :desc).each do |workflow|
      break if workflow.succeeded?
      next unless workflow.failed?

      break if pr && !matches_pr?(workflow, job, pr)
      break unless countable_failure?(workflow)

      workflows << workflow
    end
    workflows
  end
  private_class_method :consecutive_failed_agent_rebase_workflows

  def self.branch_for(workflow, job)
    stack_entry = Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT)).find do |entry|
      entry["job_id"].to_i == job.id
    end
    stack_entry&.fetch("branch_name", nil).presence || workflow.artifact(RebaseTarget::BRANCH_ARTIFACT).presence
  end

  def self.recent_failed_agent_workflow(job, pr:, since:)
    job.workflows
       .where(trigger_kind: ATTEMPT_TRIGGER_KINDS, state: "failed")
       .where("COALESCE(finished_at, updated_at) >= ?", since)
       .reorder(id: :desc)
       .detect do |workflow|
         countable_failure?(workflow) && matches_pr?(workflow, job, pr)
       end
  end
  private_class_method :recent_failed_agent_workflow

  def self.failed_in_agent_rebase?(workflow)
    workflow.steps.where(kind: AGENT_REBASE_STEPS, state: "failed").exists?
  end
  private_class_method :failed_in_agent_rebase?

  # The scan used to stop at the first workflow that did not fail in the agent
  # step, which let a deterministic failure LATER in the same chain escape the
  # cap entirely: a `force_push` that refuses to publish a branch missing its
  # latest handoff fix is non-retryable and identical every time, and one Job
  # retried it 16 times in 24 hours without the cap ever counting one of them.
  #
  # A non-retryable failure anywhere in a rebase workflow is the same situation
  # `permanently_blocked_by?` already describes -- nothing about the inputs
  # changes between attempts -- so it counts. A transient failure in a
  # non-agent step still does not, because a dead worker genuinely may succeed
  # next time.
  def self.countable_failure?(workflow)
    failed_in_agent_rebase?(workflow) || failed_non_retryably?(workflow)
  end
  private_class_method :countable_failure?

  def self.failed_non_retryably?(workflow)
    latest_failed_run(workflow)&.run_failure_classification&.retryable == false
  end
  private_class_method :failed_non_retryably?

  def self.latest_failed_run(workflow)
    workflow.steps
      .where(state: "failed")
      .order(position: :desc, id: :desc)
      .first
      &.runs
      &.order(id: :desc)
      &.first
  end
  private_class_method :latest_failed_run

  def self.matches_pr?(workflow, job, pr)
    result = result_for(workflow, job)
    return true unless result.is_a?(Hash)
    return true unless pr

    branch_name = branch_for(workflow, job)
    head_sha = pr_head_sha(pr)
    base_sha = pr_base_sha(pr)
    pre_sha = result["pre_sha"].presence || result["checkpoint_sha"].presence
    result_base_sha = result["base_sha"].presence

    return false if branch_name.present? && job.branch_name.present? && branch_name != job.branch_name
    return false if head_sha.present? && pre_sha.present? && head_sha != pre_sha
    return false if base_sha.present? && result_base_sha.present? && base_sha != result_base_sha

    true
  end
  private_class_method :matches_pr?
end
