class PluginJob < ApplicationJob
  DEFAULT_CONCURRENCY = 2
  RETRY_ATTEMPTS = 5

  class_attribute :syrus_plugin_name, instance_writer: false

  retry_on StandardError, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS do |job, error|
    job.record_terminal_failure(error)
  end

  class << self
    def plugin_name(name = nil)
      return syrus_plugin_name if name.nil?

      self.syrus_plugin_name = name.to_s
      queue_as queue_name_for(name)
      limits_concurrency(
        to: concurrency_for(name),
        key: "plugin:#{name}",
        group: "PluginJob"
      )
    end

    def queue_name_for(name)
      "plugin_#{name}"
    end

    private

    def concurrency_for(name)
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == name.to_s }
      manifest&.job_concurrency || DEFAULT_CONCURRENCY
    end
  end

  def record_terminal_failure(error)
    record = PluginRecord.find_or_initialize_by(name: self.class.plugin_name)
    record.plugin_job_failure_count = record.plugin_job_failure_count.to_i + 1
    record.plugin_job_last_failed_at = Time.current
    record.plugin_job_last_error = "#{error.class}: #{error.message}".truncate(500)
    record.save!
  rescue StandardError => health_error
    Rails.logger.error(
      "[PluginJob] failed to record terminal failure for #{self.class.plugin_name}: " \
      "#{health_error.class}: #{health_error.message}"
    )
  end
end
