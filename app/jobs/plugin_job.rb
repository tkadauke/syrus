class PluginJob < ApplicationJob
  DEFAULT_CONCURRENCY = 2
  DEFAULT_ATTEMPTS = 5

  class_attribute :plugin_slug, instance_writer: false
  class_attribute :plugin_queue_concurrency, instance_writer: false, default: DEFAULT_CONCURRENCY

  class << self
    def configure(job_class, name, concurrency: DEFAULT_CONCURRENCY)
      job_class.class_attribute :plugin_slug, instance_writer: false unless job_class.respond_to?(:plugin_slug)
      job_class.class_attribute :plugin_queue_concurrency, instance_writer: false, default: DEFAULT_CONCURRENCY unless job_class.respond_to?(:plugin_queue_concurrency)
      job_class.plugin_slug = name.to_s
      job_class.plugin_queue_concurrency = Integer(concurrency)
      job_class.queue_as { "plugin_#{self.class.plugin_slug}" }
      job_class.limits_concurrency to: job_class.plugin_queue_concurrency,
        key: ->(*) { job_class.plugin_slug },
        group: ->(*) { "plugin_#{job_class.plugin_slug}" }
      job_class.retry_on StandardError, wait: :polynomially_longer, attempts: DEFAULT_ATTEMPTS do |job, error|
        PluginJob.record_discarded_failure(job_class.plugin_slug, job.class.name, error)
      end
    end

    def record_discarded_failure(plugin_slug, job_class_name, error)
      record = PluginRecord.find_by(name: plugin_slug)
      return unless record

      record.with_lock do
        config = record.config.deep_dup
        config["job_health"] = {
          "discarded_count" => config.dig("job_health", "discarded_count").to_i + 1,
          "last_error" => "#{job_class_name}: #{error.class}: #{error.message}",
          "last_discarded_at" => Time.current.iso8601
        }
        record.update!(config:, last_error_at: Time.current)
      end
    rescue StandardError => recording_error
      Rails.logger.error("[PluginJob] failed to record discarded #{job_class_name}: #{recording_error.class}: #{recording_error.message}")
    end

    def plugin(name, concurrency: DEFAULT_CONCURRENCY)
      PluginJob.configure(self, name, concurrency:)
    end

    def plugin_queue_name
      raise "#{name} must declare its plugin with `plugin :name`" if plugin_slug.blank?

      "plugin_#{plugin_slug}"
    end
  end

  def record_discarded_failure(error)
    self.class.record_discarded_failure(self.class.plugin_slug, self.class.name, error)
  end
end
