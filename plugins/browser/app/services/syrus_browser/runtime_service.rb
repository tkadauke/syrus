module SyrusBrowser
  # The container this plugin asks Plugin Runtime to run. See
  # PluginRuntime::Service for the contract, and
  # plugins/browser/container/internal/bridge for the /healthz + reverse
  # proxy in front of @playwright/mcp that backs `healthcheck` here --
  # playwright-mcp's own HTTP transport answers every plain GET with a 4xx,
  # so nothing at its own port could otherwise serve as a health check.
  #
  # No volumes: every browser session is scoped to one MCP connection
  # (--isolated) and leaves nothing behind when it closes. No env: unlike
  # Git Mirror this service holds no secret to share with Syrus, and
  # SyrusBrowser::Session.spawn does not send any request headers to it
  # today (see Session.spawn_service), so nothing here should require one
  # the client side cannot supply yet.
  class RuntimeService
    def self.service_name = Configuration::SERVICE_NAME

    def self.service_spec
      {
        image: Configuration.image,
        internal_port: 8080,
        healthcheck: { path: Configuration::HEALTH_PATH }
      }
    end
  end
end
