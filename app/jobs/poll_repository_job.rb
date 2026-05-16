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
      issues = GithubClient.for(repository: repository, user: repository.user)
                           .issues_with_label(repository.slug, repository.trigger_label)

      issues.each do |issue|
        ingest(issue, repository)
      end
      repository.jobs.open_threads.find_each(&:start_pending_workflows_if_dependencies_satisfied!)

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
    linked = needs_lookup ? GithubClient.for(repository: repository, user: repository.user).linked_open_pr_for_issue(repository.slug, issue.number) : nil
    # Filter out our OWN PR — `closedByPullRequestsReferences` returns
    # every PR that closes this issue, including the one Syrus opened.
    # If the linked PR is ours, it's not "external preemption", just us.
    linked = nil if linked && prior&.pr_number == linked[:number]

    # Existing Job for this issue → either attach the external PR
    # discovery to it, or just dedup as before.
    if prior
      sync_issue_label_state!(prior, issue)

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
      job = Job.create!(
        user: repository.user,
        repository: repository,
        issue_number: issue.number,
        issue_title: issue_title(issue),
        issue_body: issue_body(issue),
        operator_chat_disabled: operator_chat_disabled_label_present?(issue),
        state: "closed",
        closure_reason: "preempted",
        external_pr_number: linked[:number],
        finished_at: Time.current
      )
      enqueue_issue_image_ingest(job)
      return
    end

    job = Job.create!(
      user: repository.user,
      repository: repository,
      issue_number: issue.number,
      issue_title: issue_title(issue),
      issue_body: issue_body(issue),
      skip_prepare: skip_prepare_label_present?(issue),
      operator_chat_disabled: operator_chat_disabled_label_present?(issue),
      prepare_skip_reason_override: prepare_skip_reason(issue)
    )
    enqueue_issue_image_ingest(job)
  end

  def ingest_epic_marker!(marker, issue, repository)
    case marker[:kind]
    when :epic_declaration
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
    when :child_of_epic
      ingest_child_of_epic!(marker, issue, repository)
    end
  end

  def ingest_child_of_epic!(marker, issue, repository)
    prior = latest_job_for_issue(repository, issue.number)
    if prior
      sync_issue_label_state!(prior, issue)
      Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} dedup: prior Job ##{prior.id} exists")
      return
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
      operator_chat_disabled: operator_chat_disabled_label_present?(issue),
      prepare_skip_reason_override: prepare_skip_reason(issue),
      epic: epic,
      triaging_reason: epic ? "classifier_pending" : "pending_epic_ref",
      pending_epic_reference: epic ? {} : pending_epic_reference(marker, epic_url)
    )
    job.advance_after_triage! if job.epic && job.may_advance_after_triage?
    enqueue_issue_image_ingest(job)
  end

  def latest_job_for_issue(repository, issue_number)
    Job.where(repository_id: repository.id, issue_number: issue_number).order(:created_at).last
  end

  def sync_issue_label_state!(job, issue)
    skip = skip_prepare_label_present?(issue)
    no_chat = operator_chat_disabled_label_present?(issue)

    updates = {}
    updates[:skip_prepare] = skip if job.skip_prepare? != skip
    updates[:operator_chat_disabled] = no_chat if job.operator_chat_disabled? != no_chat
    job.update!(updates) if updates.any?
  end

  def skip_prepare_label_present?(issue)
    label_names(issue).include?(Workflows::SKIP_PREPARE_LABEL)
  end

  def operator_chat_disabled_label_present?(issue)
    label_names(issue).include?(Job::OPERATOR_CHAT_OPT_OUT_LABEL)
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
