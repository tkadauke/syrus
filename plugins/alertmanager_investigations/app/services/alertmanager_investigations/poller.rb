module AlertmanagerInvestigations
  class Poller
    def self.call(...) = new(...).call

    def initialize(client: Client.new, configuration: Configuration.current, now: Time.current)
      @client = client
      @configuration = configuration
      @now = now
    end

    def call
      plugin_record.with_lock do
        @client.firing_alerts.each do |payload|
          process(Alert.new(payload: payload, host_label: @configuration.host_label))
        end
      end
    end

    private

    def process(alert)
      return if alert.runbook_url.blank?
      return if alert.host.blank?
      return if Investigation.recent_for_fingerprint(alert.fingerprint, since: @now - @configuration.rate_limit_window).exists?
      return if Investigation.open_for_host(alert.host).exists?

      runbook = RunbookResolver.call(alert.runbook_url)
      return unless runbook
      return unless runbook.repository.user

      result = InvestigationJobs::Creator.call(
        user: runbook.repository.user,
        repository: runbook.repository,
        prompt: Prompt.new(alert: alert, runbook: runbook).to_s,
        priority: "high"
      )
      raise result.error unless result.success?

      Investigation.create!(
        fingerprint: alert.fingerprint,
        host: alert.host,
        runbook_url: alert.runbook_url,
        runbook_repository: runbook.repository.slug,
        runbook_ref: runbook.ref,
        runbook_path: runbook.path,
        alert_payload: alert.payload,
        repository: runbook.repository,
        job: result.job
      )
    end

    def plugin_record
      PluginRecord.find_or_create_by!(name: "alertmanager_investigations")
    end
  end
end
