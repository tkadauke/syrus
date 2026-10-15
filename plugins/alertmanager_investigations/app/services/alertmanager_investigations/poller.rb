module AlertmanagerInvestigations
  class Poller
    def self.call(...) = new(...).call

    def initialize(client: Client.new, configuration: Configuration.current, now: Time.current)
      @client = client
      @configuration = configuration
      @now = now
    end

    def call
      @created_count = 0
      @client.firing_alerts.each do |payload|
        break if tick_limit_reached?

        alert = Alert.new(payload: payload, host_label: @configuration.host_label)
        process(alert)
      rescue StandardError => e
        record_resolution_failure(alert, e) if defined?(alert) && alert
        Rails.logger.warn("[AlertmanagerInvestigations] alert failed: #{e.class}: #{e.message}")
      end
    end

    private

    def process(alert)
      return unless alert.actionable?
      return if alert.runbook_url.blank?
      return if alert.canonical_host.blank?
      return if Investigation.recent_for_fingerprint(alert.fingerprint, since: @now - @configuration.rate_limit_window).exists?
      return if Investigation.open_for_host(alert.canonical_host).exists?

      runbook = RunbookResolver.call(alert.runbook_url)
      return record_resolution_failure(alert) unless runbook
      return record_resolution_failure(alert, "runbook repository has no owner") unless runbook.repository.user

      plugin_record.with_lock do
        return if tick_limit_reached?
        return if Investigation.recent_for_fingerprint(alert.fingerprint, since: @now - @configuration.rate_limit_window).exists?
        return if Investigation.open_for_host(alert.canonical_host).exists?
        return if repository_limit_reached?(runbook.repository)

        result = InvestigationJobs::Creator.call(
          user: runbook.repository.user,
          repository: runbook.repository,
          prompt: Prompt.new(alert: alert, runbook: runbook).to_s,
          priority: "high"
        )
        raise result.error unless result.success?

        Investigation.create!(
          fingerprint: alert.fingerprint,
          host: alert.canonical_host,
          runbook_url: alert.runbook_url,
          runbook_repository: runbook.repository.slug,
          runbook_ref: runbook.ref,
          runbook_path: runbook.path,
          alert_payload: alert.payload,
          repository: runbook.repository,
          job: result.job,
          resolution_status: "created"
        )
        @created_count += 1
      end
    end

    def record_resolution_failure(alert, error = nil)
      plugin_record.with_lock do
        return if Investigation.recent_for_fingerprint(alert.fingerprint, since: @now - @configuration.rate_limit_window).exists?

        Investigation.create!(
          fingerprint: alert.fingerprint,
          host: alert.canonical_host,
          runbook_url: alert.runbook_url,
          alert_payload: alert.payload,
          resolution_status: "failed",
          resolution_error: error.to_s.presence
        )
      end
    rescue StandardError => record_error
      Rails.logger.warn("[AlertmanagerInvestigations] could not record failed resolution: #{record_error.class}: #{record_error.message}")
    end

    def tick_limit_reached?
      @created_count >= @configuration.max_jobs_per_tick
    end

    def repository_limit_reached?(repository)
      Investigation.open_for_repository(repository).count >= @configuration.max_open_jobs_per_repository
    end

    def plugin_record
      PluginRecord.find_or_create_by!(name: "alertmanager_investigations")
    end
  end
end
