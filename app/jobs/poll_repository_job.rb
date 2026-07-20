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

    previous_poll_started_at = repository.last_poll_started_at
    incremental_since = force ? nil : previous_poll_started_at
    repository.update_columns(last_poll_started_at: Time.current, last_poll_status: nil, last_poll_error: nil)

    begin
      client = GithubClient.for(repository: repository, user: repository.user)
      issues = list_labeled_issues(client, repository, since: incremental_since)
      closed_issues = list_labeled_issues(client, repository, state: "closed", since: incremental_since)

      stats = Hash.new(0)
      issues.each do |issue|
        stats[ingest(issue, repository, client: client)] += 1
      end
      closed_jobs = close_jobs_for_closed_issues!(repository, closed_issues)
      repository.jobs.open_threads.find_each(&:start_pending_workflows_if_dependencies_satisfied!)

      log_poll_summary(repository, issues: issues, closed_issues: closed_issues, closed_jobs: closed_jobs, stats: stats, incremental_since: incremental_since)
      repository.update_columns(last_poll_status: "ok", last_poll_error: nil)
    rescue => e
      repository.update_columns(last_poll_status: "failed", last_poll_error: e.message)
      raise
    end
  end

  private

  def list_labeled_issues(client, repository, state: "open", since: nil)
    if since.present?
      client.issues_with_label(repository.slug, repository.trigger_label, state: state, since: since)
    else
      client.issues_with_label(repository.slug, repository.trigger_label, state: state)
    end
  end

  def log_poll_summary(repository, issues:, closed_issues:, closed_jobs:, stats:, incremental_since:)
    counts = {
      seen: Array(issues).size,
      closed_seen: Array(closed_issues).size,
      created: stats[:created],
      deduped: stats[:deduped],
      skipped: stats[:skipped],
      epics: stats[:epic],
      preempted: stats[:preempted],
      preempt_attached: stats[:preempt_attached],
      closed_jobs: closed_jobs
    }
    mode = incremental_since.present? ? "incremental since=#{incremental_since.iso8601}" : "full"
    Rails.logger.info("[PollRepositoryJob] #{repository.slug} #{mode} poll: #{counts.map { |key, value| "#{key}=#{value}" }.join(" ")}")
  end

  def ingest(issue, repository, client:)
    decision = IngestPolicy.evaluate(issue, repository)
    unless decision.allow
      return :skipped
    end

    marker = EpicMarkerParser.parse(text: issue_body(issue), default_repository: repository)
    return ingest_epic_marker!(marker, issue, repository) if marker

    prior = latest_job_for_issue(repository, issue.number)

    # Look up linked PRs for any issue we might still act on — i.e.
    # brand-new issues *and* any open Job, regardless of whether
    # Syrus has shipped its own PR or has a Run mid-flight. That way
    # a human PR landing on an in-flight or mid-failure Job surfaces
    # immediately. Skip only fully-closed Jobs (they're terminal and
    # the lookup would be wasted).
    needs_lookup = prior.nil? || prior.open?
    linked = needs_lookup ? client.linked_open_pr_for_issue(repository.slug, issue.number) : nil
    # Filter out our OWN PR — `closedByPullRequestsReferences` returns
    # every PR that closes this issue, including the one Syrus opened.
    # If the linked PR is ours, it's not "external preemption", just us.
    linked = nil if linked && prior&.pr_number == linked[:number]

    # Existing Job for this issue → either attach the external PR
    # discovery to it, or just dedup as before.
    if prior
      sync_issue_label_state!(prior, issue)

      if linked && prior.external_pr_number != linked[:number]
        Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} preempt-attach to #{prior.slug}: external PR ##{linked[:number]}")
        prior.update!(external_pr_number: linked[:number])
        # If Syrus has nothing in flight here, close the thread as
        # preempted so the operator sees the right state. Open Jobs
        # with an active Run are left alone — that agent finishes and
        # the duplicate-PR situation gets surfaced at PR-opening time.
        if prior.open? && prior.pr_number.blank? && !prior.any_active_run?
          prior.cancel_active_runs_and_close!("preempted")
        end
        return :preempt_attached
      else
        return :deduped
      end
    end

    # Brand-new issue — preempted at first sight: record the Job in
    # closed state and don't schedule a Run.
    if linked
      Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} preempted by PR ##{linked[:number]}")
      job = Job.create!(
        user: repository.user,
        repository: repository,
        issue_number: issue.number,
        issue_title: issue_title(issue),
        issue_body: issue_body(issue),
        state: "closed",
        closure_reason: "preempted",
        external_pr_number: linked[:number],
        finished_at: Time.current
      )
      enqueue_issue_image_ingest(job)
      return :preempted
    end

    job = Job.create!(
      user: repository.user,
      repository: repository,
      issue_number: issue.number,
      issue_title: issue_title(issue),
      issue_body: issue_body(issue),
      state: initial_state_for_issue(issue),
      skip_prepare: skip_prepare_label_present?(issue),
      prepare_skip_reason_override: prepare_skip_reason(issue)
    )
    classify_if_available(job)
    enqueue_issue_image_ingest(job)
    :created
  end

  def close_jobs_for_closed_issues!(repository, issues)
    issue_numbers = Array(issues)
      .reject { |issue| pull_request_issue?(issue) }
      .select { |issue| issue.state.to_s == "closed" }
      .map(&:number)
      .compact
      .uniq
    return 0 if issue_numbers.empty?

    jobs = repository.jobs
      .issue_kind
      .open_threads
      .without_pr
      .where(issue_number: issue_numbers)

    closed = 0
    jobs.find_each do |job|
      Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{job.issue_number} closed upstream; closing #{job.slug}")
      job.cancel_active_runs_and_close!("issue_closed")
      closed += 1
    end
    closed
  end

  def pull_request_issue?(issue)
    issue.respond_to?(:pull_request) && issue.pull_request.present?
  end

  def ingest_epic_marker!(marker, issue, repository)
    send(:"ingest_#{marker[:kind]}!", marker, issue, repository)
  end

  def ingest_epic_declaration!(marker, issue, repository)
    epic_url = issue_url(repository, issue.number)
    Epic.find_or_create_by!(
      user: repository.user,
      repository: repository,
      github_issue_url: epic_url
    ) do |epic|
      epic.title = marker[:name]
      epic.description = issue_body(issue)
    end
    Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} ingested as Epic")
    :epic
  end

  def ingest_child_of_epic!(marker, issue, repository)
    prior = latest_job_for_issue(repository, issue.number)
    if prior
      sync_issue_label_state!(prior, issue)
      return :deduped
    end

    epic_url = issue_url_for_reference(marker)
    epic = repository.user.epics.find_by(github_issue_url: epic_url)
    job = Job.create!(
      user: repository.user,
      repository: repository,
      issue_number: issue.number,
      issue_title: issue_title(issue),
      issue_body: issue_body(issue),
      skip_prepare: skip_prepare_label_present?(issue),
      prepare_skip_reason_override: prepare_skip_reason(issue),
      epic: epic,
      state: initial_state_for_issue(issue),
      triaging_reason: epic ? "classifier_pending" : "pending_epic_ref",
      pending_epic_reference: epic ? {} : pending_epic_reference(marker, epic_url)
    )
    job.advance_after_triage! if job.epic && job.may_advance_after_triage?
    enqueue_issue_image_ingest(job)
    :created
  end

  # Hand off to a background job rather than running the classifier
  # inline. The classifier spawns an agent subprocess that can take
  # tens of seconds; running it in the poll frame meant a deploy
  # SIGKILL during the agent call left Jobs stuck in
  # triaging/classifier_pending forever (the poll's dedup logic
  # never re-tries existing Jobs). SolidQueue's at-least-once
  # delivery lets a fresh worker pick up the classify after a
  # restart. See ClassifyIssueJob + ReapClassifierPendingJob.
  def classify_if_available(job)
    return unless job.triaging? && job.triaging_reason_classifier_pending?
    return unless job.user.agent_provider_configured?(job.agent_provider)

    ClassifyIssueJob.perform_later(job.id)
  end

  def latest_job_for_issue(repository, issue_number)
    Job.where(repository_id: repository.id, issue_number: issue_number).order(:created_at).last
  end

  def sync_issue_label_state!(job, issue)
    skip = skip_prepare_label_present?(issue)

    updates = {}
    updates[:skip_prepare] = skip if job.skip_prepare? != skip
    job.update!(updates) if updates.any?
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

  def issue_title(issue)
    issue.respond_to?(:title) ? issue.title : nil
  end

  def issue_body(issue)
    issue.respond_to?(:body) ? issue.body : nil
  end

  def initial_state_for_issue(issue)
    Job.initial_state_for_creator(syrus_issue_creator(issue))
  end

  def syrus_issue_creator(issue)
    login = issue.respond_to?(:user) ? issue.user&.login.to_s.strip : ""
    return if login.blank?

    User.where("LOWER(github_handle) = ?", login.downcase).first
  end

  def issue_url(repository, issue_number)
    "https://github.com/#{repository.owner}/#{repository.name}/issues/#{issue_number}"
  end

  def issue_url_for_reference(reference)
    "https://github.com/#{reference[:owner]}/#{reference[:repo]}/issues/#{reference[:number]}"
  end

  def pending_epic_reference(reference, github_issue_url)
    {
      "owner" => reference[:owner],
      "repo" => reference[:repo],
      "number" => reference[:number],
      "github_issue_url" => github_issue_url
    }
  end

  def enqueue_issue_image_ingest(job)
    return if IssueImageExtractor.urls(job.issue_body).empty?

    IngestIssueImagesJob.perform_later(job.id)
  end
end
