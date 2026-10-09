class PollRepositoryJob < ApplicationJob
  include SkipIfPending
  include GithubPollingRateLimitGuard

  queue_as :polling
  UNTAGGED_OPEN_ISSUE_REFRESH_INTERVAL = 1.hour
  LINKED_OPEN_PR_LOOKUP_LIMIT = 50
  MAX_TRANSIENT_GITHUB_RETRIES = 5
  TRANSIENT_GITHUB_RETRY_BASE_DELAY = 1.minute
  TRANSIENT_GITHUB_RETRY_MAX_DELAY = 30.minutes
  TRANSIENT_GITHUB_RETRY_RESET_BUFFER = 5.seconds
  TRANSIENT_GITHUB_ERROR_CLASSES = [
    Octokit::ServerError,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed
  ].freeze

  # Serialize per-repo polling so a manual "Poll now" click can't race
  # the recurring schedule past the dedup check.
  limits_concurrency to: 1, key: ->(repo_id, *) { "poll:#{repo_id}" }

  def perform(repository_id, force: false, transient_retry_attempt: 0)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    # Archive is stricter than polling-off — it blocks even force: true
    # so a stale "Poll now" tab can't reanimate an archived repo.
    return if repository.archived?
    return unless force || repository.polling_enabled?
    if !force && repository.github_api_rate_limited_for?(user: repository.user)
      return handle_transient_github_failure(
        repository,
        "GitHub API rate limit exhausted",
        force: force,
        retry_attempt: transient_retry_attempt,
        wait_until: reset_with_buffer(github_polling_rate_limit_reset_at(repository, user: repository.user))
      )
    end

    previous_poll_started_at = repository.last_poll_started_at
    incremental_since = force ? nil : previous_poll_started_at
    poll_started_at = Time.current

    client = GithubClient.for(repository: repository, user: repository.user)
    listed_issues = list_labeled_issues(client, repository, since: incremental_since)
    retried_issues = retry_quarantined_issues(client, repository, listed_issues: listed_issues, at: poll_started_at)
    issues = open_issues_for_ingestion(listed_issues + retried_issues)
    closed_issues = unique_issues_by_number(
      list_labeled_issues(client, repository, state: "closed", since: incremental_since) + closed_issues_for_resolution(retried_issues)
    )
    prior_jobs_by_issue_number = latest_jobs_by_issue_number(repository, issues)
    linked_lookup_candidates = linked_open_pr_lookup_issue_numbers(issues, prior_jobs_by_issue_number)
    linked_lookup_issue_numbers = linked_lookup_candidates.first(LINKED_OPEN_PR_LOOKUP_LIMIT)
    linked_lookup_overflow_numbers = linked_lookup_candidates.drop(LINKED_OPEN_PR_LOOKUP_LIMIT).index_with(true)
    linked_open_prs = linked_lookup_issue_numbers.any? ? client.linked_open_prs_for_issues(repository.slug, linked_lookup_issue_numbers) : {}
    linked_lookup_numbers = linked_lookup_issue_numbers.index_with(true)

    stats = Hash.new(0)
    issues.each do |issue|
      result = ingest_with_quarantine(
        issue,
        repository,
        prior_jobs_by_issue_number: prior_jobs_by_issue_number,
        linked_open_prs: linked_open_prs,
        linked_lookup_numbers: linked_lookup_numbers,
        linked_lookup_overflow_numbers: linked_lookup_overflow_numbers
      )
      stats[result] += 1
      repository.clear_poll_issue_error!(issue_number: issue.number) unless %i[ quarantined deferred ].include?(result)
    end
    closed_jobs = close_jobs_for_closed_issues!(repository, closed_issues)
    clear_closed_poll_issue_errors!(repository, closed_issues)
    InputSources::PendingWorkWakeup.call(repository)
    update_untagged_open_issue_count!(repository, client)

    log_poll_summary(repository, issues: issues, closed_issues: closed_issues, closed_jobs: closed_jobs, stats: stats, incremental_since: incremental_since)
    if linked_lookup_overflow_numbers.any?
      Rails.logger.info(
        "[PollRepositoryJob] #{repository.slug} deferred #{linked_lookup_overflow_numbers.size} " \
        "issue(s) until a later poll to stay within the linked-PR lookup budget"
      )
    end
    success_at = linked_lookup_overflow_numbers.any? ? nil : poll_started_at
    repository.mark_poll_success!(at: success_at, clear_issue_errors: false)
  rescue Octokit::TooManyRequests => e
    handle_transient_github_failure(repository, e, force: force, retry_attempt: transient_retry_attempt)
  rescue *TRANSIENT_GITHUB_ERROR_CLASSES => e
    handle_transient_github_failure(repository, e, force: force, retry_attempt: transient_retry_attempt)
  rescue => e
    if repository
      repository.mark_poll_failure!(e.message)
    end
    raise
  end

  private

  def handle_transient_github_failure(repository, error, force:, retry_attempt:, wait_until: nil)
    message = transient_github_error_message(error)
    repository.mark_poll_failure!(message) if repository

    if retry_attempt >= MAX_TRANSIENT_GITHUB_RETRIES
      Rails.logger.warn(
        "[PollRepositoryJob] #{repository&.slug || "unknown"}: transient GitHub polling failure " \
        "after #{retry_attempt} retry attempt(s); leaving repository marked failed - #{message}"
      )
      return
    end

    next_attempt = retry_attempt + 1
    retry_at = transient_github_retry_at(error, repository: repository, attempt: next_attempt, wait_until: wait_until)
    Rails.logger.warn(
      "[PollRepositoryJob] #{repository&.slug || "unknown"}: transient GitHub polling failure; " \
      "retry #{next_attempt}/#{MAX_TRANSIENT_GITHUB_RETRIES} at #{retry_at.utc.iso8601} - #{message}"
    )
    self.class.set(wait_until: retry_at).perform_later(repository.id, force: force, transient_retry_attempt: next_attempt)
  end

  def transient_github_error_message(error)
    return error if error.is_a?(String)

    "#{error.class}: #{error.message}"
  end

  def transient_github_retry_at(error, repository:, attempt:, wait_until:)
    retry_after = retry_after_at(error)
    candidates = [
      wait_until,
      rate_limit_reset_at(error),
      reset_with_buffer(github_polling_rate_limit_reset_at(repository, user: repository&.user))
    ].compact.select { |candidate| candidate > Time.current }
    retry_at = candidates.min || exponential_retry_at(attempt)
    return retry_at unless retry_after&.future?

    [ retry_at, retry_after ].max
  end

  def retry_after_at(error)
    value = github_error_header(error, "retry-after")
    return if value.blank?

    seconds = Integer(value, exception: false)
    return seconds.seconds.from_now if seconds

    Time.httpdate(value)
  rescue ArgumentError
    nil
  end

  def rate_limit_reset_at(error)
    reset_epoch = github_error_header(error, "x-ratelimit-reset")
    return if reset_epoch.blank?

    epoch = Integer(reset_epoch, exception: false)
    reset_with_buffer(epoch ? Time.at(epoch) : nil)
  end

  def github_error_header(error, name)
    headers = error.respond_to?(:response_headers) ? error.response_headers : nil
    return unless headers

    canonical = name.split("-").map(&:capitalize).join("-")
    headers[name] || headers[name.downcase] || headers[name.upcase] || headers[canonical] ||
      headers[name.to_sym] || headers[name.downcase.to_sym] || headers[canonical.to_sym]
  rescue NoMethodError
    nil
  end

  def reset_with_buffer(reset_at)
    reset_at ? reset_at + TRANSIENT_GITHUB_RETRY_RESET_BUFFER : nil
  end

  def exponential_retry_at(attempt)
    delay = TRANSIENT_GITHUB_RETRY_BASE_DELAY * (2 ** (attempt - 1))
    [ delay, TRANSIENT_GITHUB_RETRY_MAX_DELAY ].min.from_now
  end

  # Best-effort, cheap dashboard signal — never part of the ingestion
  # contract. A failure here (rate limit, transient GitHub error) must
  # not fail the poll or block labeled-issue ingestion.
  def update_untagged_open_issue_count!(repository, client)
    return if repository.archived? || !repository.polling_enabled?
    return unless untagged_open_issue_count_stale?(repository)

    open_issues = client.list_all_issues(repository.slug, state: "open")
    untagged_count = open_issues.count { |issue| untagged?(issue, repository) }
    repository.update_columns(
      untagged_open_issue_count: untagged_count,
      untagged_open_issues_checked_at: Time.current
    )
  rescue => e
    Rails.logger.warn("[PollRepositoryJob] #{repository.slug} failed to refresh untagged open issue count: #{e.message}")
  end

  def untagged_open_issue_count_stale?(repository)
    repository.untagged_open_issues_checked_at.blank? ||
      repository.untagged_open_issues_checked_at < UNTAGGED_OPEN_ISSUE_REFRESH_INTERVAL.ago
  end

  def untagged?(issue, repository)
    names = label_names(issue)
    !names.include?(repository.trigger_label) && !names.include?(IngestPolicy::SKIP_LABEL)
  end

  def list_labeled_issues(client, repository, state: "open", since: nil)
    if since.present?
      client.issues_with_label(repository.slug, repository.trigger_label, state: state, since: since)
    else
      client.issues_with_label(repository.slug, repository.trigger_label, state: state)
    end
  end

  def retry_quarantined_issues(client, repository, listed_issues:, at:)
    listed_numbers = Array(listed_issues).map(&:number).compact.index_with(true)
    retry_numbers = repository.poll_issue_numbers_due_for_retry(at: at).reject { |number| listed_numbers[number] }
    return [] if retry_numbers.empty?

    retry_numbers.filter_map do |number|
      client.fetch_issue(repository.slug, number)
    rescue Octokit::NotFound
      repository.clear_poll_issue_error!(issue_number: number)
      nil
    end
  end

  def open_issues_for_ingestion(issues)
    unique_issues_by_number(Array(issues).select { |issue| issue.state.to_s != "closed" })
  end

  def closed_issues_for_resolution(issues)
    unique_issues_by_number(Array(issues).select { |issue| issue.state.to_s == "closed" })
  end

  def unique_issues_by_number(issues)
    Array(issues).reverse.index_by(&:number).values.reverse
  end

  def clear_closed_poll_issue_errors!(repository, issues)
    Array(issues).each do |issue|
      repository.clear_poll_issue_error!(issue_number: issue.number)
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
      quarantined: stats[:quarantined],
      deferred: stats[:deferred],
      closed_jobs: closed_jobs
    }
    mode = incremental_since.present? ? "incremental since=#{incremental_since.iso8601}" : "full"
    Rails.logger.info("[PollRepositoryJob] #{repository.slug} #{mode} poll: #{counts.map { |key, value| "#{key}=#{value}" }.join(" ")}")
  end

  def ingest_with_quarantine(
    issue,
    repository,
    prior_jobs_by_issue_number:,
    linked_open_prs:,
    linked_lookup_numbers:,
    linked_lookup_overflow_numbers:
  )
    ingest(
      issue,
      repository,
      prior_jobs_by_issue_number: prior_jobs_by_issue_number,
      linked_open_prs: linked_open_prs,
      linked_lookup_numbers: linked_lookup_numbers,
      linked_lookup_overflow_numbers: linked_lookup_overflow_numbers
    )
  rescue Octokit::TooManyRequests, *TRANSIENT_GITHUB_ERROR_CLASSES
    raise
  rescue => e
    repository.record_poll_issue_error!(
      issue_number: issue.number,
      issue_title: issue_title(issue),
      error: e
    )
    Rails.logger.error("[PollRepositoryJob] #{repository.slug}##{issue.number} quarantined after ingestion failure: #{e.class}: #{e.message}")
    :quarantined
  end

  def latest_jobs_by_issue_number(repository, issues)
    issue_numbers = Array(issues).map(&:number).compact.uniq
    return {} if issue_numbers.empty?

    Job.where(repository_id: repository.id, issue_number: issue_numbers)
      .order(:issue_number, :created_at, :id)
      .each_with_object({}) do |job, latest|
        latest[job.issue_number] = job
      end
  end

  def linked_open_pr_lookup_issue_numbers(issues, prior_jobs_by_issue_number)
    Array(issues).filter_map do |issue|
      number = issue.number
      prior = prior_jobs_by_issue_number[number]
      next number if prior.nil?
      next unless prior.open?
      next number if linked_open_pr_lookup_stale?(prior, issue)

      nil
    end.uniq
  end

  def linked_open_pr_lookup_stale?(job, issue)
    checked_at = job.linked_open_pr_checked_at
    return true if checked_at.blank?

    updated_at = issue_updated_at(issue)
    return false if updated_at.blank?

    updated_at > checked_at
  end

  def issue_updated_at(issue)
    return unless issue.respond_to?(:updated_at)

    value = issue.updated_at
    value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def ingest(
    issue,
    repository,
    prior_jobs_by_issue_number:,
    linked_open_prs:,
    linked_lookup_numbers:,
    linked_lookup_overflow_numbers:
  )
    decision = IngestPolicy.evaluate(issue, repository)
    unless decision.allow
      return :skipped
    end

    marker = EpicMarkerParser.parse(text: issue_body(issue), default_repository: repository)
    return ingest_epic_marker!(marker, issue, repository) if marker

    prior = prior_jobs_by_issue_number[issue.number]

    # Look up linked PRs for any issue we might still act on — i.e.
    # brand-new issues *and* any open Job, regardless of whether
    # Syrus has shipped its own PR or has a Run mid-flight. That way
    # a human PR landing on an in-flight or mid-failure Job surfaces
    # immediately. Skip only fully-closed Jobs (they're terminal and
    # the lookup would be wasted).
    needs_lookup = prior.nil? || prior.open?
    return :deferred if needs_lookup && linked_lookup_overflow_numbers.include?(issue.number)

    looked_up_linked_pr = needs_lookup && linked_lookup_numbers.include?(issue.number)
    linked = looked_up_linked_pr ? linked_open_prs[issue.number] : nil
    # Filter out our OWN PR — `closedByPullRequestsReferences` returns
    # every PR that closes this issue, including the one Syrus opened.
    # If the linked PR is ours, it's not "external preemption", just us.
    linked = nil if linked && prior&.pr_number == linked[:number]

    # Existing Job for this issue → either attach the external PR
    # discovery to it, or just dedup as before.
    if prior
      sync_issue_label_state!(prior, issue)
      prior.update_columns(linked_open_pr_checked_at: Time.current) if looked_up_linked_pr

      if linked && prior.external_pr_number != linked[:number]
        Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} preempt-attach to #{prior.slug}: external PR ##{linked[:number]}")
        prior.mark_externally_implemented!(linked[:number]) if prior.open?
        return :preempt_attached
      else
        return :deduped
      end
    end

    # Brand-new issue — already implemented externally at first sight.
    # Keep the issue-backed Job reviewable without scheduling an agent Run.
    if linked
      Rails.logger.info("[PollRepositoryJob] #{repository.slug}##{issue.number} implemented by external PR ##{linked[:number]}")
      job = Job.create!(
        user: repository.user,
        repository: repository,
        issue_number: issue.number,
        issue_title: issue_title(issue),
        issue_body: issue_body(issue),
        state: "implemented",
        external_pr_number: linked[:number],
        linked_open_pr_checked_at: Time.current
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
      prepare_skip_reason_override: prepare_skip_reason(issue),
      delivery_track: delivery_track_label_value(issue),
      investigation: investigation_label_present?(issue),
      linked_open_pr_checked_at: looked_up_linked_pr ? Time.current : nil
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
    job = nil
    Job.transaction do
      job = Job.create!(
        user: repository.user,
        repository: repository,
        issue_number: issue.number,
        issue_title: issue_title(issue),
        issue_body: issue_body(issue),
        skip_prepare: skip_prepare_label_present?(issue),
        prepare_skip_reason_override: prepare_skip_reason(issue),
        delivery_track: delivery_track_label_value(issue),
        investigation: investigation_label_present?(issue),
        epic: epic,
        state: initial_state_for_issue(issue),
        triaging_reason: epic ? "classifier_pending" : "pending_epic_ref",
        pending_epic_reference: epic ? {} : pending_epic_reference(marker, epic_url)
      )
      validate_github_epic_child_chain!(job) if job.epic
      job.advance_after_triage! if job.may_advance_after_triage?
    end
    enqueue_issue_image_ingest(job)
    :created
  end

  def validate_github_epic_child_chain!(job)
    return unless job.epic_id

    sibling_scope = job.epic.jobs.where.not(id: job.id)
    return unless sibling_scope.exists?

    return if same_epic_upstream_dependency?(job)
    return if same_epic_downstream_dependency?(job)
    return if pending_github_issue_dependency?(job)

    job.errors.add(
      :base,
      "GitHub-ingested Epic children must form one linear dependency chain. " \
      "Add a Depends-on: line that references the previous child issue in this Epic, " \
      "or make another child depend on this issue if it is the chain head."
    )
    raise ActiveRecord::RecordInvalid, job
  end

  def same_epic_upstream_dependency?(job)
    job.dependencies.joins(:depends_on_job).where(jobs: { epic_id: job.epic_id }).exists?
  end

  def same_epic_downstream_dependency?(job)
    JobDependency.joins(:job).where(depends_on_job_id: job.id, jobs: { epic_id: job.epic_id }).exists?
  end

  def pending_github_issue_dependency?(job)
    job.dependencies.pending.where(
      unresolved_owner: job.epic.repository.owner,
      unresolved_repo: job.epic.repository.name
    ).exists?
  end

  # Hand off to a background job rather than running the classifier
  # inline. The classifier spawns an agent subprocess that can take
  # tens of seconds; running it in the poll frame meant a deploy
  # SIGKILL during the agent call left Jobs stuck in
  # triaging/classifier_pending forever (the poll's dedup logic
  # never re-tries existing Jobs). SolidQueue's at-least-once
  # delivery lets a fresh worker pick up the classify after a
  # restart. See ClassifyIssueJob; WorkEngine::Reconciler reaps stalled ones.
  def classify_if_available(job)
    return unless job.triaging? && job.triaging_reason_classifier_pending?
    return unless job.user.agent_provider_configured?(job.workflow_agent_provider)

    ClassifyIssueJob.perform_later(job.id)
  end

  def latest_job_for_issue(repository, issue_number)
    Job.where(repository_id: repository.id, issue_number: issue_number).order(:created_at).last
  end

  def sync_issue_label_state!(job, issue)
    skip = skip_prepare_label_present?(issue)
    track = delivery_track_label_value(issue)

    updates = {}
    updates[:skip_prepare] = skip if job.skip_prepare? != skip
    updates[:delivery_track] = track if job.delivery_track != track
    job.update!(updates) if updates.any?
  end

  def skip_prepare_label_present?(issue)
    label_names(issue).include?(Workflows::SKIP_PREPARE_LABEL)
  end

  def delivery_track_label_value(issue)
    Workflows.track_label_value(issue.labels)
  end

  # Read once at ingest. Adding the label to an already-ingested issue does
  # not retro-convert the Job: its chain is chosen when the first workflow is
  # instantiated, so flipping it later would leave the Job claiming to be an
  # investigation while running the implementation chain.
  def investigation_label_present?(issue)
    label_names(issue).include?(Workflows::INVESTIGATION_LABEL)
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
