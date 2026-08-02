class PollRebaseJob < ApplicationJob
  include GithubPrPollHelpers

  queue_as :default

  # Cap how many consecutive failed rebase attempts we make per Job
  # before giving up. The second attempt usually succeeds when the
  # first didn't (transient CI noise, GitHub mergeable computation
  # lag). Five consecutive failures means the agent can't resolve the
  # conflict mechanically — bail and surface to the operator.
  # Successful rebases reset the counter (long-lived PRs that rebase
  # cleanly many times should never be blocked).
  REBASE_ATTEMPT_CAP = RebaseAttemptGuard::ATTEMPT_CAP

  # Concurrent-rebase cap per repository on the AUTONOMOUS poller
  # path. Pathological case: someone merges a schema.rb timestamp
  # change to main, every other open Job's PR becomes unmergeable
  # in the same poll cycle, and the auto-rebase loop instantiates
  # one Rebase workflow per Job — O(n) workflows hitting the same
  # workspace pool simultaneously. Bound that fan-out here. Manual
  # rebases via the Job detail command bypass this cap (operator
  # explicitly asked for it).
  CONCURRENT_REBASES_PER_REPO = 3

  # One concurrent poll per Job — the same Job's rebase poll
  # shouldn't race itself or stack two rebase Runs at once.
  limits_concurrency to: 1, key: ->(job_id) { "rebase_poll:#{job_id}" }

  # `bypass_cache: true` is set by the on-demand "Check now" button on
  # Job#show. The periodic poller (PollAllMergeStatesJob → PollMergeStateJob)
  # leaves it false so the conditional-GET / 304 cycle keeps it cheap;
  # operator-initiated checks pay a fresh request to defeat GitHub's
  # eventual-consistency lag on the `mergeable` field.
  def self.enqueue_manual_check(job_id)
    if perform_accepts_bypass_cache?
      perform_later(job_id, bypass_cache: true)
    else
      perform_later(job_id)
    end
  end

  def perform(job_id, bypass_cache: false)
    @job = Job.find_by(id: job_id)
    return unless @job
    # Archived repos are explicitly out — the operator has retired
    # them; we shouldn't keep rebasing their stale PRs. Mirrors the
    # archived-repo guard in PollRepositoryJob.
    return if @job.repository.archived?

    pr_number = @job.pr_number || @job.external_pr_number
    return unless pr_number

    pr_repo = @job.effective_pr_repository
    @client = GithubClient.for(repository: pr_repo, user: @job.user)
    pr = @client.pull_request(pr_repo.slug, pr_number, bypass_cache: bypass_cache)

    # Cache what GitHub told us so the show page doesn't have to call
    # back here on every render. Persist BEFORE any early returns so
    # closed/merged/draft PRs also show their last-known status.
    persist_mergeability(pr)

    return if pr.merged
    return if pr.state == "closed"

    # mergeable is true/false/null. Null = GitHub is still computing
    # mergeability after a recent push; try again next cycle. Only act
    # on a definitive false.
    return if pr.mergeable.nil?
    return if pr.mergeable                # mergeable; nothing to do

    return unless we_control_head?(pr)    # head from a fork → can't push
    return if start_blocked?
    return if noop_rebase_already_covers?(pr)
    return if pending_rebase?
    return if attempt_cap_reached?(pr)
    return if repo_rebase_concurrency_reached?

    Rails.logger.info("[PollRebaseJob] #{@job.slug} PR ##{pr_number} unmergeable; instantiating rebase workflow")
    workflow = RebaseWorkflowSelector.instantiate(job: @job, pr: pr)
    StepDispatcher.start_workflow(workflow)
  end

  def persist_mergeability(pr)
    # update! (not update_columns) so callbacks observing mergeability
    # changes still fire.
    MergeabilityRecorder.record_github!(job: @job, pr: pr)
  end

  def self.perform_accepts_bypass_cache?
    instance_method(:perform).parameters.any? do |kind, name|
      kind == :keyrest || (name == :bypass_cache && kind.in?(%i[key keyreq]))
    end
  end
  private_class_method :perform_accepts_bypass_cache?

  private

  def pending_rebase?
    RebaseWorkflowSelector.active_for_stack?(@job)
  end

  def noop_rebase_already_covers?(pr)
    return false unless RebaseLoopGuard.noop_rebase_for?(job: @job, pr: pr, client: @client)

    Rails.logger.info("[PollRebaseJob] #{@job.slug} PR ##{@job.pr_number || @job.external_pr_number} still unmergeable after no-op rebase for same head/base; waiting")
    true
  end

  def start_blocked?
    if @job.dependencies_failed_for_execution?
      Rails.logger.info("[PollRebaseJob] #{@job.slug} PR ##{@job.pr_number || @job.external_pr_number} unmergeable but a dependency failed; skipping rebase dispatch")
      return true
    end

    unless @job.dependencies_satisfied_for_execution?
      Rails.logger.info("[PollRebaseJob] #{@job.slug} PR ##{@job.pr_number || @job.external_pr_number} unmergeable but dependencies are not ready for execution; skipping rebase dispatch")
      return true
    end

    unless @job.ready_for_execution?
      Rails.logger.info("[PollRebaseJob] #{@job.slug} PR ##{@job.pr_number || @job.external_pr_number} unmergeable but job is not ready for execution; skipping rebase dispatch")
      return true
    end

    false
  end

  def attempt_cap_reached?(pr)
    return false unless RebaseAttemptGuard.cap_reached?(@job, pr: pr)

    Rails.logger.info("[PollRebaseJob] #{@job.slug} hit rebase cap (#{REBASE_ATTEMPT_CAP} consecutive failures); skipping")
    true
  end

  # Counts CURRENTLY ACTIVE (queued/running) Rebase workflows across
  # every Job in this Job's repository. Defends the fan-out case
  # described in the constant — autonomous polling doesn't open the
  # floodgates when many PRs become unmergeable at once.
  def repo_rebase_concurrency_reached?
    active = RebaseWorkflowSelector.active_in_repository(@job.repository).count
    return false if active < CONCURRENT_REBASES_PER_REPO
    Rails.logger.info("[PollRebaseJob] #{@job.slug} repo #{@job.repository.slug} at concurrent-rebase cap (#{active}/#{CONCURRENT_REBASES_PER_REPO}); deferring")
    true
  end
end
