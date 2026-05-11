class PollRepositoryJob < ApplicationJob
  queue_as :default

  # Serialize per-repo polling so a manual "Poll now" click can't race
  # the recurring schedule past the dedup check.
  limits_concurrency to: 1, key: ->(repo_id, *) { "poll:#{repo_id}" }

  def perform(repository_id, force: false)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    # Archive is stricter than polling-off — it blocks even force: true
    # so a stale "Poll now" tab can't reanimate an archived repo.
    return if repository.archived?
    return unless force || repository.polling_enabled?

    repository.update_columns(last_poll_started_at: Time.current, last_poll_status: nil, last_poll_error: nil)

    begin
      issues = GithubClient.for(repository.user)
                           .issues_with_label(repository.slug, repository.trigger_label)

      issues.each do |issue|
        ingest(issue, repository)
      end

      repository.update_columns(last_poll_status: "ok", last_poll_error: nil)
    rescue => e
      repository.update_columns(last_poll_status: "failed", last_poll_error: e.message)
      raise
    end
  end

  private

  def ingest(issue, repository)
    decision = IngestPolicy.evaluate(issue, repository)
    unless decision.allow
      Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} skipped: #{decision.reason}")
      return
    end

    prior = latest_job_for_issue(repository, issue.number)

    # Look up linked PRs for any issue we might still act on — i.e.
    # brand-new issues *and* any open Job, regardless of whether
    # Syrus has shipped its own PR or has a Run mid-flight. That way
    # a human PR landing on an in-flight or mid-failure Job surfaces
    # immediately. Skip only fully-closed Jobs (they're terminal and
    # the lookup would be wasted).
    needs_lookup = prior.nil? || prior.open?
    linked = needs_lookup ? GithubClient.for(repository.user).linked_open_pr_for_issue(repository.slug, issue.number) : nil
    # Filter out our OWN PR — `closedByPullRequestsReferences` returns
    # every PR that closes this issue, including the one Syrus opened.
    # If the linked PR is ours, it's not "external preemption", just us.
    linked = nil if linked && prior&.pr_number == linked[:number]

    # Existing Job for this issue → either attach the external PR
    # discovery to it, or just dedup as before.
    if prior
      sync_skip_prepare!(prior, issue)

      if linked && prior.external_pr_number != linked[:number]
        Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} preempt-attach to Job ##{prior.id}: external PR ##{linked[:number]}")
        prior.update!(external_pr_number: linked[:number])
        # If Syrus has nothing in flight here, close the thread as
        # preempted so the operator sees the right state. Open Jobs
        # with an active Run are left alone — that agent finishes and
        # the duplicate-PR situation gets surfaced at PR-opening time.
        if prior.open? && prior.pr_number.blank? && !prior.any_active_run?
          prior.cancel_active_runs_and_close!("preempted")
        end
      else
        Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} dedup: prior Job ##{prior.id} exists")
      end
      return
    end

    # Brand-new issue — preempted at first sight: record the Job in
    # closed state and don't schedule a Run.
    if linked
      Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} preempted by PR ##{linked[:number]}")
      Job.create!(
        user: repository.user,
        repository: repository,
        issue_number: issue.number,
        state: "closed",
        closure_reason: "preempted",
        external_pr_number: linked[:number],
        finished_at: Time.current
      )
      return
    end

    Job.create!(
      user: repository.user,
      repository: repository,
      issue_number: issue.number,
      skip_prepare: skip_prepare_label_present?(issue),
      prepare_skip_reason_override: prepare_skip_reason(issue)
    )
  end

  def latest_job_for_issue(repository, issue_number)
    Job.where(repository_id: repository.id, issue_number: issue_number).order(:created_at).last
  end

  def sync_skip_prepare!(job, issue)
    skip = skip_prepare_label_present?(issue)
    job.update!(skip_prepare: skip) if job.skip_prepare? != skip
  end

  def skip_prepare_label_present?(issue)
    label_names(issue).include?(Workflows::SKIP_PREPARE_LABEL)
  end

  def label_names(issue)
    Workflows.label_names(issue.labels)
  end

  def prepare_skip_reason(issue)
    "issue_label" if label_names(issue).include?(Job::PREPARE_SKIP_LABEL)
  end
end
