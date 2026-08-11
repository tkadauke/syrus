# Start registered platform polling jobs on application boot when running
# as a server process (worker or web pod with SYRUS_ROLE set). Each
# subclass of PlatformPollingJob re-enqueues itself after every poll cycle,
# so this initializer only needs to prime the pump on a fresh start.
#
# Core connectors (Telegram) start via PlatformPollingJob.start_all!, which
# walks its own inheritance-based registry. Plugin-provided connectors
# (registered under the :platform_delivery extension point) start via
# PlatformDelivery::Registry.start_connectors! instead, so a disabled
# plugin's connector job does not start.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    next unless SyrusVersion.server_process?

    begin
      PlatformPollingJob.start_all!
    rescue StandardError => e
      Rails.logger.warn("[PlatformPollingJob] boot start failed: #{e.class}: #{e.message}")
    end

    begin
      PlatformDelivery::Registry.start_connectors!
    rescue StandardError => e
      Rails.logger.warn("[PlatformDelivery::Registry] connector boot start failed: #{e.class}: #{e.message}")
    end
  end
end
