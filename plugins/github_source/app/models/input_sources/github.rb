module InputSources
  class Github < InputSource
    include Syrus::Plugin::InputSource

    def poll!
      return if repository.archived?
      return unless polling_enabled?

      repository.update_columns(
        last_poll_started_at: Time.current,
        last_poll_status: nil,
        last_poll_error: nil
      )

      begin
        client = GithubClient.for(repository: repository, user: user)
        issues = client.issues_with_label(repository.slug, trigger_label)
        closed_issues = client.issues_with_label(repository.slug, trigger_label, state: "closed")

        issues.each { |issue| ingest(issue) }
        close_jobs_for_closed_issues!(closed_issues)
        repository.jobs.open_threads.find_each(&:start_pending_workflows_if_dependencies_satisfied!)

        repository.update_columns(last_poll_status: "ok", last_poll_error: nil)
      rescue => e
        repository.update_columns(last_poll_status: "failed", last_poll_error: e.message)
        raise
      end
    end

    def validate_credentials!
      client = GithubClient.for(repository: repository, user: user)
      client.repository(repository.slug)
    rescue => e
      raise "GitHub credentials invalid or repository inaccessible: #{e.message}"
    end

    def config_schema
      [
        { key: "trigger_label", type: "string", required: true, label: "Trigger label", scope: "config" }
      ]
    end

    def dedup_key(issue)
      issue[:number].to_s
    end

    def trigger_label
      config["trigger_label"].presence || "syrus"
    end

    private

    def ingest(issue)
      decision = IngestPolicy.evaluate(issue, repository)
      unless decision.allow
        Rails.logger.info("[InputSources::Github] #{repository.slug}##{issue.number} skipped: #{decision.reason}")
        return
      end

      marker = EpicMarkerParser.parse(text: issue_body(issue), default_repository: repository)
      return ingest_epic_marker!(marker, issue) if marker

      prior = latest_job_for_issue(issue.number)

      needs_lookup = prior.nil? || prior.open?
      linked = needs_lookup ? GithubClient.for(repository: repository, user: user).linked_open_pr_for_issue(repository.slug, issue.number) : nil
      linked = nil if linked && prior&.pr_number == linked[:number]

      if prior
        sync_issue_label_state!(prior, issue)

        if linked && prior.external_pr_number != linked[:number]
          Rails.logger.info("[InputSources::Github] #{repository.slug}##{issue.number} preempt-attach to #{prior.slug}: external PR ##{linked[:number]}")
          prior.update!(external_pr_number: linked[:number])
          if prior.open? && prior.pr_number.blank? && !prior.any_active_run?
            prior.cancel_active_runs_and_close!("preempted")
          end
        else
          Rails.logger.info("[InputSources::Github] #{repository.slug}##{issue.number} dedup: prior #{prior.slug} exists")
        end
        return
      end

      if linked
        Rails.logger.info("[InputSources::Github] #{repository.slug}##{issue.number} preempted by PR ##{linked[:number]}")
        job = Job.create!(
          user: user,
          repository: repository,
          issue_number: issue.number,
          issue_title: issue_title(issue),
          issue_body: issue_body(issue),
          state: "closed",
          closure_reason: "preempted",
          external_pr_number: linked[:number],
          finished_at: Time.current,
          input_source: self,
          external_ref: dedup_key(issue)
        )
        enqueue_issue_image_ingest(job)
        return
      end

      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: issue.number,
        issue_title: issue_title(issue),
        issue_body: issue_body(issue),
        state: initial_state_for_issue(issue),
        skip_prepare: skip_prepare_label_present?(issue),
        prepare_skip_reason_override: prepare_skip_reason(issue),
        input_source: self,
        external_ref: dedup_key(issue)
      )
      classify_if_available(job)
      enqueue_issue_image_ingest(job)
    end

    def close_jobs_for_closed_issues!(issues)
      issue_numbers = Array(issues)
        .reject { |issue| pull_request_issue?(issue) }
        .select { |issue| issue.state.to_s == "closed" }
        .map(&:number)
        .compact
        .uniq
      return if issue_numbers.empty?

      repository.jobs
        .issue_kind
        .open_threads
        .without_pr
        .where(issue_number: issue_numbers)
        .find_each do |job|
          Rails.logger.info("[InputSources::Github] #{repository.slug}##{job.issue_number} closed upstream; closing #{job.slug}")
          job.cancel_active_runs_and_close!("issue_closed")
        end
    end

    def pull_request_issue?(issue)
      issue.respond_to?(:pull_request) && issue.pull_request.present?
    end

    def ingest_epic_marker!(marker, issue)
      case marker[:kind]
      when :epic_declaration
        epic_url = issue_url(issue.number)
        Epic.find_or_create_by!(
          user: user,
          repository: repository,
          github_issue_url: epic_url
        ) do |epic|
          epic.title = marker[:name]
          epic.description = issue_body(issue)
        end
        Rails.logger.info("[InputSources::Github] #{repository.slug}##{issue.number} ingested as Epic")
      when :child_of_epic
        ingest_child_of_epic!(marker, issue)
      end
    end

    def ingest_child_of_epic!(marker, issue)
      prior = latest_job_for_issue(issue.number)
      if prior
        sync_issue_label_state!(prior, issue)
        Rails.logger.info("[InputSources::Github] #{repository.slug}##{issue.number} dedup: prior #{prior.slug} exists")
        return
      end

      epic_url = issue_url_for_reference(marker)
      epic = user.epics.find_by(github_issue_url: epic_url)
      job = Job.create!(
        user: user,
        repository: repository,
        issue_number: issue.number,
        issue_title: issue_title(issue),
        issue_body: issue_body(issue),
        skip_prepare: skip_prepare_label_present?(issue),
        prepare_skip_reason_override: prepare_skip_reason(issue),
        epic: epic,
        state: initial_state_for_issue(issue),
        triaging_reason: epic ? "classifier_pending" : "pending_epic_ref",
        pending_epic_reference: epic ? {} : pending_epic_reference(marker, epic_url),
        input_source: self,
        external_ref: dedup_key(issue)
      )
      job.advance_after_triage! if job.epic && job.may_advance_after_triage?
      enqueue_issue_image_ingest(job)
    end

    def classify_if_available(job)
      return unless job.triaging? && job.triaging_reason_classifier_pending?
      return unless job.user.agent_provider_configured?(job.agent_provider)

      ClassifyIssueJob.perform_later(job.id)
    end

    def latest_job_for_issue(issue_number)
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

    def issue_url(issue_number)
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
end
