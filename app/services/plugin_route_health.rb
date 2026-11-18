class PluginRouteHealth
  ERROR_WRITE_INTERVAL = 1.minute

  class << self
    def record_request(plugin_name)
      PluginRecord.where(name: plugin_name).update_all("request_count = request_count + 1")
    rescue ActiveRecord::ActiveRecordError => error
      log_recording_failure(plugin_name, error)
    end

    def record_error(plugin_name, error)
      timestamp = Time.current
      begin
        PluginRecord
          .where(name: plugin_name)
          .where("last_error_at IS NULL OR last_error_at < ?", timestamp - ERROR_WRITE_INTERVAL)
          .update_all(last_error_at: timestamp)
      rescue ActiveRecord::ActiveRecordError => recording_error
        log_recording_failure(plugin_name, recording_error)
      end

      Syrus::PluginInvocation.runtime_health.record_failure(
        plugin: plugin_name,
        extension_point: :route,
        operation: :dispatch,
        exception: error,
        threshold: Syrus::PluginInvocation::DEFAULT_FAILURE_THRESHOLD,
        window: Syrus::PluginInvocation::DEFAULT_FAILURE_WINDOW,
        cooldown: Syrus::PluginInvocation::DEFAULT_COOLDOWN,
        circuit: false
      )
    end

    private

    def log_recording_failure(plugin_name, error)
      Rails.logger.warn("[PluginRouteHealth] failed to record health for #{plugin_name}: #{error.class}: #{error.message}")
    end
  end
end
