class PlatformPollingJob < ApplicationJob
  queue_as :polling

  @registry = []

  class << self
    def registry
      @registry
    end

    def inherited(subclass)
      super
      @registry << subclass
    end

    # Enqueue configured registered subclasses that are not already running.
    # Tolerates missing SolidQueue tables (non-server environments). Excludes
    # subclasses that a plugin registered as its :platform_delivery
    # .connector_job_class -- those start via PlatformDelivery::Registry
    # .start_connectors! instead, which respects PluginRecord enable/disable.
    def start_all!
      start_all_with_status!.select { |result| result[:status] == :started }.map { |result| result[:name] }
    end

    # Same as start_all! but returns every registry entry's outcome, not just
    # the ones newly started -- callers that need to show/log why a connector
    # did or didn't start (admin restart endpoint, the connector watchdog)
    # use this instead of the name-only array.
    def start_all_with_status!
      registry.reject { |klass| plugin_managed_connector?(klass) }.map { |klass| start_one_with_status(klass) }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("PlatformPollingJob.start_all! skipped: #{e.message}")
      []
    end

    def start_one(klass)
      result = start_one_with_status(klass)
      result[:name] if result[:status] == :started
    end

    # { name:, status:, platform?: } where status is :started,
    # :already_running, :not_configured, or :error. `platform` is included
    # when the subclass declares its own .platform_key (core connectors like
    # PollTelegramUpdatesJob do this directly); plugin connectors don't
    # implement it here -- PlatformDelivery::Registry merges the owning
    # provider's .platform_key in instead, since the job class itself only
    # knows the plugin, not the platform key the plugin registered under.
    def start_one_with_status(klass)
      identity = { name: klass.name }.merge(platform_fields(klass))
      return identity.merge(status: :not_configured) unless klass.new.send(:configured?)
      return identity.merge(status: :already_running) if SolidQueue::Job.where(class_name: klass.name, finished_at: nil).exists?

      klass.perform_later
      identity.merge(status: :started)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("PlatformPollingJob.start_one skipped for #{klass.name}: #{e.message}")
      identity.merge(status: :error)
    end

    private

    def platform_fields(klass)
      klass.respond_to?(:platform_key) && klass.platform_key.present? ? { platform: klass.platform_key.to_s } : {}
    end

    # True when `klass` is registered by ANY plugin (enabled or not) as its
    # platform_delivery .connector_job_class, regardless of whether Ruby's
    # `inherited` hook also picked it up into `registry`.
    def plugin_managed_connector?(klass)
      Syrus::PluginRegistry.all_plugins.any? do |manifest|
        Array(manifest.provides[:platform_delivery]).any? do |provider|
          provider.respond_to?(:connector_job_class) && provider.connector_job_class == klass
        end
      end
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end

  def perform
    return unless configured?
    return if duplicate_running?
    poll_once
  rescue => e
    Rails.logger.error("#{self.class}: #{e}")
  ensure
    self.class.perform_later if configured?
  end

  private

  def configured? = raise NotImplementedError
  def poll_once   = raise NotImplementedError

  def duplicate_running?
    SolidQueue::Job
      .where(class_name: self.class.name, finished_at: nil)
      .count > 1
  rescue ActiveRecord::StatementInvalid
    false
  end
end
