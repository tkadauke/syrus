class PluginJob < ApplicationJob
  DEFAULT_CONCURRENCY = 2
  DEFAULT_CONCURRENCY_DURATION = 15.minutes
  DEFAULT_ATTEMPTS = 5

  class_attribute :plugin_slug, instance_writer: false
  class_attribute :plugin_queue_concurrency, instance_writer: false, default: DEFAULT_CONCURRENCY

  class << self
    def configure(job_class, name, concurrency: DEFAULT_CONCURRENCY, concurrency_duration: DEFAULT_CONCURRENCY_DURATION)
      job_class.class_attribute :plugin_slug, instance_writer: false unless job_class.respond_to?(:plugin_slug)
      job_class.class_attribute :plugin_queue_concurrency, instance_writer: false, default: DEFAULT_CONCURRENCY unless job_class.respond_to?(:plugin_queue_concurrency)
      job_class.plugin_slug = name.to_s
      job_class.plugin_queue_concurrency = Integer(concurrency)
      job_class.queue_as { "plugin_#{self.class.plugin_slug}" }
      job_class.limits_concurrency to: job_class.plugin_queue_concurrency,
        key: ->(*) { job_class.plugin_slug },
        group: ->(*) { "plugin_#{job_class.plugin_slug}" },
        duration: concurrency_duration
      job_class.around_perform do |job, block|
        PluginJob.with_concurrency_lease(job) { block.call }
      end
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

    def plugin(name, concurrency: DEFAULT_CONCURRENCY, concurrency_duration: DEFAULT_CONCURRENCY_DURATION)
      PluginJob.configure(self, name, concurrency:, concurrency_duration:)
    end

    def with_concurrency_lease(job)
      mutex = Mutex.new
      condition = ConditionVariable.new
      stopped = false
      interval = [ job.class.concurrency_duration / 3, 5.minutes ].min
      renewer = Thread.new do
        Thread.current.name = "plugin-concurrency-lease" if Thread.current.respond_to?(:name=)
        loop do
          break if mutex.synchronize do
            condition.wait(mutex, interval) unless stopped
            stopped
          end

          renew_concurrency_lease(job)
        end
      end

      yield
    ensure
      if renewer
        mutex.synchronize do
          stopped = true
          condition.broadcast
        end
        renewer.join
      end
    end

    def renew_concurrency_lease(job)
      ActiveRecord::Base.connection_pool.with_connection do
        SolidQueue::Semaphore.where(key: job.concurrency_key)
          .update_all(expires_at: job.class.concurrency_duration.from_now)
      end
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("[PluginJob] failed to renew #{job.class.name} concurrency lease: #{error.class}: #{error.message}")
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
