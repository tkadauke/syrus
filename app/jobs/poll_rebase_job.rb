class PollRebaseJob < ApplicationJob
  queue_as :default

  # Cap how many consecutive failed rebase attempts we make per Job
  # before giving up. The second attempt usually succeeds when the
  # first didn't (transient CI noise, GitHub mergeable computation
  # lag). Five consecutive failures means the agent can't resolve the
  # conflict mechanically — bail and surface to the operator.
  # Successful rebases reset the counter (long-lived PRs that rebase
  # cleanly many times should never be blocked).
  REBASE_ATTEMPT_CAP = 5

  # Concurrent-rebase cap per repository on the AUTONOMOUS poller
  # path. Pathological case: someone merges a schema.rb timestamp
  # change to main, every other open Job's PR becomes unmergeable
  # in the same poll cycle, and the auto-rebase loop instantiates
  # one Rebase workflow per Job — O(n) workflows hitting the same
  # workspace pool simultaneously. Bound that fan-out here. Manual
  # rebases via JobsController#rebase bypass this cap (operator
  # explicitly asked for it).
  CONCURRENT_REBASES_PER_REPO = 3

  # One concurrent poll per Job — the same Job's rebase poll
  # shouldn't race itself or stack two rebase Runs at once.
  limits_concurrency to: 1, key: ->(job_id) { "rebase_poll:#{job_id}" }

  # `bypass_cache: true` is set by the on-demand "Check now" button on
  # Job#show. The periodic poller (PollAllRebasesJob → PollRebaseJob)
  # leaves it false so the conditional-GET / 304 cycle keeps it cheap;
  # operator-initiated checks pay a fresh request to defeat GitHub's
  # eventual-consistency lag on the `mergeable` field.
  def perform(job_id, bypass_cache: false)
    @job = Job.find_by(id: job_id)
    return unless @job
    # Archived repos are explicitly out — the operator has retired
    # them; we shouldn't keep rebasing their stale PRs. Mirrors the
    # archived-repo guard in PollRepositoryJob.
    return if @job.repository.archived?

    pr_number = @job.pr_number || @job.external_pr_number
    return unless pr_number

    @client = GithubClient.for(@job.user)
    pr = @client.pull_request(@job.repository.slug, pr_number, bypass_cache: bypass_cache)

    # Cache what GitHub told us so the show page doesn't have to call
    # back here on every render. Persist BEFORE any early returns so
    # closed/merged/draft PRs also show their last-known status.
    persist_mergeable(pr.mergeable)

    return if pr.merged
    return if pr.state == "closed"

    # mergeable is true/false/null. Null = GitHub is still computing
    # mergeability after a recent push; try again next cycle. Only act
    # on a definitive false.
    return if pr.mergeable.nil?
    return if pr.mergeable                # mergeable; nothing to do

    return unless we_control_head?(pr)    # head from a fork → can't push
    return if pending_rebase?
    return if attempt_cap_reached?
    return if repo_rebase_concurrency_reached?

    # Instantiate a Rebase workflow. Its first step is
    # Steps::AutoRebase, which runs the deterministic AutoRebase
    # service; if that's clean, it skips agent_rebase and advances
    # to force_push. If conflicts remain, the chain advances to the
    # agentic step, then force_push.
    Rails.logger.info("[PollRebaseJob] job #{@job.id} PR ##{pr_number} unmergeable; instantiating Rebase workflow")
    workflow = Workflows::Rebase.instantiate(job: @job)
    StepDispatcher.start_workflow(workflow)
  end

  def persist_mergeable(value)
    # update! (not update_columns) so the after_update_commit
    # broadcasts_refreshes hook fires and morphs the Job show page if
    # the operator is watching it.
    @job.update!(
      pr_mergeable: value,
      pr_mergeable_checked_at: Time.current
    )
  end

  private

  # Same-repo head means we have push access via the operator's
  # github_token. Forks would need maintainer-edits opt-in and a
  # different push URL; out of scope for v1.
  def we_control_head?(pr)
    pr.head&.repo&.full_name == pr.base&.repo&.full_name
  end

  def pending_rebase?
    @job.workflows.active.where(trigger_kind: "rebase").exists?
  end

  def attempt_cap_reached?
    consecutive = 0
    @job.workflows.where(trigger_kind: "rebase").reorder(id: :desc).each do |w|
      break if w.succeeded?
      consecutive += 1 if w.failed?
      # queued/running/cancelled don't count toward or reset the streak
    end
    return false if consecutive < REBASE_ATTEMPT_CAP
    Rails.logger.info("[PollRebaseJob] job #{@job.id} hit rebase cap (#{REBASE_ATTEMPT_CAP} consecutive failures); skipping")
    true
  end

  # Counts CURRENTLY ACTIVE (queued/running) Rebase workflows across
  # every Job in this Job's repository. Defends the fan-out case
  # described in the constant — autonomous polling doesn't open the
  # floodgates when many PRs become unmergeable at once.
  def repo_rebase_concurrency_reached?
    active = Workflow.active
                     .where(trigger_kind: "rebase")
                     .joins(:job)
                     .where(jobs: { repository_id: @job.repository_id })
                     .count
    return false if active < CONCURRENT_REBASES_PER_REPO
    Rails.logger.info("[PollRebaseJob] job #{@job.id} repo #{@job.repository.slug} at concurrent-rebase cap (#{active}/#{CONCURRENT_REBASES_PER_REPO}); deferring")
    true
  end
end
