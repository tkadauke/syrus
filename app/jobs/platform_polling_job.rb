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
      registry.reject { |klass| plugin_managed_connector?(klass) }.filter_map { |klass| start_one(klass) }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("PlatformPollingJob.start_all! skipped: #{e.message}")
      []
    end

    def start_one(klass)
      return unless klass.new.send(:configured?)
      return if SolidQueue::Job.where(class_name: klass.name, finished_at: nil).exists?

      klass.perform_later
      klass.name
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("PlatformPollingJob.start_one skipped for #{klass.name}: #{e.message}")
      nil
    end

    private

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
