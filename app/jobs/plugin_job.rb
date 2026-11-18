class PluginJob < ApplicationJob
  DEFAULT_CONCURRENCY = 2
  MAX_ATTEMPTS = 5

  class_attribute :declared_plugin_owner, :plugin_source_path, :plugin_concurrency_override, instance_writer: false

  queue_as { self.class.plugin_queue_name }
  limits_concurrency key: ->(*) { self.class.plugin_owner }, group: "plugin_jobs"

  retry_on StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS do |job, error|
    job.class.record_discard(error)
  end

  class << self
    def limits_concurrency(to: 1, **options)
      super
      self.plugin_concurrency_override = to unless self == PluginJob
    end

    def owned_by_plugin(name)
      self.declared_plugin_owner = name.to_s
    end

    def inherited(subclass)
      subclass.plugin_source_path = caller_locations(1, 8).map(&:absolute_path).compact.find { |path| path.include?("/app/jobs/") }
      super
    end

    def plugin_owner
      declared_plugin_owner.presence || bundled_plugin_owner || external_plugin_owner
    end

    def plugin_queue_name
      raise ArgumentError, "#{name} must declare owned_by_plugin or live under a registered plugin root" if plugin_owner.blank?

      "plugin_#{plugin_owner.parameterize(separator: "_")}"
    end

    def concurrency_limit
      return plugin_concurrency_override if plugin_concurrency_override

      plugin_manifest&.job_concurrency || DEFAULT_CONCURRENCY
    end

    def record_discard(error)
      return if plugin_owner.blank?

      redacted_message = CommandRedactor.redact(error.message)
      redacted_error = error.dup
      redacted_error.define_singleton_method(:message) { redacted_message }

      PluginRecord.where(name: plugin_owner).update_all(last_error_at: Time.current)
      Syrus::PluginInvocation.runtime_health.record_failure(
        plugin: plugin_owner,
        extension_point: :background_job,
        operation: name,
        exception: redacted_error,
        threshold: 1,
        window: 1.hour,
        cooldown: 1.hour,
        circuit: false
      )
      Rails.logger.error("[PluginJob] discarded #{name} for #{plugin_owner} after #{MAX_ATTEMPTS} attempts: #{error.class}: #{redacted_message}")
    rescue StandardError => recording_error
      Rails.logger.error(
        "[PluginJob] failed to record discarded #{name}: " \
        "#{recording_error.class}: #{CommandRedactor.redact(recording_error.message)}"
      )
    end

    private

    def bundled_plugin_owner
      plugin_source_path&.match(%r{/plugins/([^/]+)/app/jobs/})&.captures&.first
    end

    def external_plugin_owner
      manifest = Syrus::PluginRegistry.all_plugins.find do |candidate|
        candidate.plugin_root.present? && plugin_source_path.to_s.start_with?(File.expand_path(candidate.plugin_root.to_s) + File::SEPARATOR)
      end
      manifest&.name
    end

    def plugin_manifest
      Syrus::PluginRegistry.all_plugins.find { |manifest| manifest.name == plugin_owner }
    end
  end
end
