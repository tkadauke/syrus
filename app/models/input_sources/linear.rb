module InputSources
  class Linear < InputSource
    def poll!
      return unless polling_enabled?

      repository.update_columns(
        last_poll_started_at: Time.current,
        last_poll_status: nil,
        last_poll_error: nil
      )

      begin
        api_key = credentials&.dig("api_key").to_s
        raise "Linear API key is not configured" if api_key.blank?

        team_id = config["team_id"].to_s
        raise "Linear team ID is not configured" if team_id.blank?

        client = LinearClient.new(api_key: api_key)
        issues = client.issues(team_id: team_id, label_name: label_filter)

        if issues.nil?
          Rails.logger.warn("[InputSources::Linear] #{repository.slug} rate limited; skipping poll")
          repository.update_columns(last_poll_status: "ok")
          return
        end

        issues.each { |issue| ingest(issue) }
        repository.jobs.open_threads.find_each(&:start_pending_workflows_if_dependencies_satisfied!)

        repository.update_columns(last_poll_status: "ok", last_poll_error: nil)
      rescue => e
        repository.update_columns(last_poll_status: "failed", last_poll_error: e.message)
        raise
      end
    end

    def validate_credentials!
      api_key = credentials&.dig("api_key").to_s
      raise "Linear API key is required" if api_key.blank?

      client = LinearClient.new(api_key: api_key)
      viewer = client.viewer
      raise "Invalid or rate-limited Linear API key — could not authenticate" if viewer.nil?
    rescue => e
      raise e if e.message.start_with?("Linear API key is required")
      raise "Linear credentials invalid: #{e.message}"
    end

    def config_schema
      [
        { key: "team_id", type: "string", required: true, label: "Team ID" },
        { key: "label_filter", type: "string", required: false, label: "Label filter" }
      ]
    end

    def dedup_key(issue)
      issue["id"]
    end

    def label_filter
      config["label_filter"].presence
    end

    def issues_ingested_count
      Job.where(input_source_id: id).count
    end

    private

    def ingest(issue)
      decision = LinearIngestPolicy.evaluate(issue)
      unless decision.allow
        Rails.logger.info("[InputSources::Linear] #{repository.slug} #{issue['identifier']} skipped: #{decision.reason}")
        return
      end

      prior = existing_job_for_issue(issue["id"])
      if prior
        Rails.logger.info("[InputSources::Linear] #{repository.slug} #{issue['identifier']} dedup: prior #{prior.slug} exists")
        return
      end

      issue_body = issue["description"].to_s
      marker = EpicMarkerParser.parse(text: issue_body, default_repository: repository)
      if marker
        ingest_with_epic_marker!(marker, issue, issue_body)
        return
      end

      Job.create!(
        user: user,
        repository: repository,
        issue_title: issue["title"].to_s,
        issue_body: issue_body,
        state: Job.initial_state_for_creator(nil),
        input_source: self,
        external_ref: dedup_key(issue)
      )
      Rails.logger.info("[InputSources::Linear] #{repository.slug} #{issue['identifier']} ingested as Job")
    end

    def existing_job_for_issue(issue_id)
      Job.where(input_source_id: id, external_ref: issue_id).open_threads.order(:created_at).last
    end

    def ingest_with_epic_marker!(marker, issue, issue_body)
      case marker[:kind]
      when :epic_declaration
        Epic.find_or_create_by!(
          user: user,
          repository: repository,
          github_issue_url: nil
        ) do |epic|
          epic.title = marker[:name]
          epic.description = issue_body
        end
        Rails.logger.info("[InputSources::Linear] #{repository.slug} #{issue['identifier']} ingested as Epic")
      when :child_of_epic
        epic_url = issue_url_for_reference(marker)
        epic = user.epics.find_by(github_issue_url: epic_url)
        job = Job.create!(
          user: user,
          repository: repository,
          issue_title: issue["title"].to_s,
          issue_body: issue_body,
          state: Job.initial_state_for_creator(nil),
          epic: epic,
          triaging_reason: epic ? "classifier_pending" : "pending_epic_ref",
          pending_epic_reference: epic ? {} : { "github_issue_url" => epic_url },
          input_source: self,
          external_ref: dedup_key(issue)
        )
        job.advance_after_triage! if job.epic && job.may_advance_after_triage?
        Rails.logger.info("[InputSources::Linear] #{repository.slug} #{issue['identifier']} ingested as child-of-epic Job")
      end
    end

    def issue_url_for_reference(reference)
      "https://github.com/#{reference[:owner]}/#{reference[:repo]}/issues/#{reference[:number]}"
    end
  end
end
