class PollMergeStateJob < ApplicationJob
  queue_as :default
  REBASE_MERGEABLE_STATES = %w[behind dirty].freeze

  limits_concurrency to: 1, key: ->(job_id) { "merge_state_poll:#{job_id}" }

  def perform(job_id)
    @job = Job.find_by(id: job_id)
    return unless @job

    # Cover both Syrus-authored PRs and external PRs owned by the
    # current user (the preempted-Job ingest path) — same scope as
    # the per-Job rebase worker uses.
    pr_number = @job.pr_number || @job.external_pr_number
    return unless pr_number
    return if @job.repository.archived?
    return if @job.workflows.active.exists?

    @client = GithubClient.for(@job.user)
    @pr = @client.pull_request(@job.repository.slug, pr_number, bypass_cache: true)
    persist_mergeable(@pr.mergeable)

    return if @pr.merged
    return if @pr.state == "closed"
    return unless we_control_head?(@pr)

    gate = AutoMergeGate.new(job: @job, client: @client, bypass_cache: true, pr: @pr).evaluate
    if gate.merge_ready?
      dispatch_auto_merge
    elsif gate.approved? && rebaseable_mergeable_state?
      dispatch_rebase
    elsif !gate.approved? && mergeable_state == "behind"
      dispatch_rebase
    end
  end

  private

  def persist_mergeable(value)
    @job.update!(
      pr_mergeable: value,
      pr_mergeable_checked_at: Time.current
    )
  end

  def mergeable_state
    @pr.respond_to?(:mergeable_state) ? @pr.mergeable_state : nil
  end

  def rebaseable_mergeable_state?
    REBASE_MERGEABLE_STATES.include?(mergeable_state)
  end

  def dispatch_auto_merge
    workflow = Workflows::AutoMerge.instantiate(job: @job)
    audit("auto_merge: dispatching workflow ##{workflow.id} for PR ##{@job.pr_number}")
    Rails.logger.info("[PollMergeStateJob] job #{@job.id} PR ##{@job.pr_number} approved and clean; instantiating AutoMerge workflow")
    StepDispatcher.start_workflow(workflow)
  end

  def dispatch_rebase
    return if attempt_cap_reached?
    return if repo_rebase_concurrency_reached?

    workflow = Workflows::Rebase.instantiate(job: @job)
    audit("auto_merge: dispatching rebase workflow ##{workflow.id} before merge")
    Rails.logger.info("[PollMergeStateJob] job #{@job.id} PR ##{@job.pr_number} needs rebase before merge-state evaluation")
    StepDispatcher.start_workflow(workflow)
  end

  def we_control_head?(pr)
    pr.head&.repo&.full_name == pr.base&.repo&.full_name
  end

  def audit(message)
    run = @job.current_run
    return unless run

    seq = (run.job_logs.maximum(:sequence) || -1) + 1
    run.job_logs.create!(chunk: message, sequence: seq, kind: "system")
  end

  def attempt_cap_reached?
    consecutive = 0
    @job.workflows.where(trigger_kind: "rebase").reorder(id: :desc).each do |workflow|
      break if workflow.succeeded?
      consecutive += 1 if workflow.failed?
    end
    consecutive >= PollRebaseJob::REBASE_ATTEMPT_CAP
  end

  def repo_rebase_concurrency_reached?
    active = Workflow.active
                     .where(trigger_kind: "rebase")
                     .joins(:job)
                     .where(jobs: { repository_id: @job.repository_id })
                     .count
    active >= PollRebaseJob::CONCURRENT_REBASES_PER_REPO
  end
end
