# Build the worker-local MCP server before Solid Queue advertises this process
# and accepts agent work. Lazy construction makes the first agent race the MCP
# health-check timeout while the full plugin tool registry is still loading.
Rails.application.config.to_prepare do
  next unless SyrusVersion.server_process? && SyrusVersion.role == "worker"
  next unless Feature.persistent_mcp_sidecar_enabled?

  daemon = PersistentMcpDaemon.ensure_started
  health = daemon&.health_check
  next if health&.fetch(:status, nil) == "ok"

  Rails.logger.warn("[PersistentMcpDaemon] worker boot prewarm failed: #{health.inspect}")
rescue NameError
  # Zeitwerk may be between reload cycles in development. A subsequent
  # to_prepare pass or the transport selector will retry startup.
end
