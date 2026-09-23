module PluginRuntime
  # One service's state as of the last reconcile.
  #
  # `mode` is "managed" when the runtime manager runs it and "external" when an
  # operator does. `state` uses the manager's vocabulary (absent, pulling,
  # starting, running, unhealthy, stopped, error) plus two of the runtime's
  # own: "unavailable" when the manager itself could not be reached, and
  # "unconfigured" when an external service has no address set.
  ServiceStatus = Data.define(:service, :plugin, :mode, :state, :endpoint, :image, :error, :pull, :checked_at, :privileged) do
    def self.build(service:, plugin:, mode:, state:, endpoint: nil, image: nil, error: nil, pull: nil, privileged: false)
      new(service:, plugin:, mode:, state:, endpoint:, image:, error:, pull:, checked_at: Time.current.iso8601, privileged:)
    end

    def self.from_manager(payload, plugin:)
      build(
        service: payload.fetch("service"),
        plugin: plugin,
        mode: "managed",
        state: payload.fetch("state"),
        endpoint: payload["endpoint"],
        image: payload["image"],
        error: payload["error"],
        pull: payload["pull"],
        privileged: payload["privileged"] || false
      )
    end

    # Only a service that answered its health check is handed out. Anything
    # else -- still pulling, starting, broken -- reads as "not available", and
    # callers carry on without it.
    def available?
      state == "running" && endpoint.present?
    end
  end
end
