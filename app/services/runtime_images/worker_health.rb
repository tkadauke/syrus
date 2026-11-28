module RuntimeImages
  module WorkerHealth
    WINDOW = 24.hours

    module_function

    def snapshot(hostname: Socket.gethostname, now: Time.current)
      configuration = OciRegistry::Configuration.from_env
      active_bases = CoworkerBaseRelease.active.includes(:runtime_image).to_a
      corrupt = RuntimeImagePullEvent.since(now - WINDOW).where(hostname:, outcome: "corrupt").count
      auth_failed = RuntimeImageAuditEvent.since(now - WINDOW).where(event_type: "auth", outcome: "failed").exists?
      successful_pull = RuntimeImagePullEvent.since(now - WINDOW).where(hostname:, outcome: %w[hit pulled]).exists?
      {
        "registry_access" => registry_access(configuration, auth_failed:, successful_pull:),
        "cache_integrity" => corrupt.zero? ? "ok" : "failed",
        "cache_integrity_failures_24h" => corrupt,
        "base_abis" => active_bases.map(&:runtime_abi).uniq.sort,
        "base_abi_compatible" => active_bases.all? { |base| RuntimeAbi.supported?(base.runtime_abi) },
        "termination_support" => SpawnedProcess.column_names.include?("kill_requested_at")
      }
    rescue StandardError => error
      Rails.logger.warn("[RuntimeImages::WorkerHealth] probe failed: #{error.class}: #{error.message}")
      { "probe_error" => error.class.name }
    end

    def registry_access(configuration, auth_failed:, successful_pull:)
      return "unavailable" unless configuration&.credential?(:worker)
      return "failed" if auth_failed
      return "ok" if successful_pull

      "configured_unverified"
    end
    private_class_method :registry_access
  end
end
