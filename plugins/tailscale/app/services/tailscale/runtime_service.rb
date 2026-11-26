module Tailscale
  # The container this plugin asks Plugin Runtime's privileged lane to run.
  # See PluginRuntime::PrivilegedService for the contract, and
  # docs/plans/tailscale-privileged-service-lane.md for why Tailscale needs
  # that lane instead of the generic "plugin_runtime:service" point every
  # other container-backed plugin uses: it needs NET_ADMIN/NET_RAW and
  # /dev/net/tun, which the generic path can never express.
  #
  # Unlike GitMirror::RuntimeService, there is no service_spec here: image,
  # internal port, capabilities, devices, and the state volume are all fixed
  # in the runtime manager's compiled internal/privileged.Registry (Go), not
  # something this class can configure even by mistake.
  class RuntimeService
    def self.privileged_service_name = "tailscale"

    # Evaluated on every reconcile, so a rotated auth key or a settings change
    # takes effect on the next tick. Raises when no auth key is configured --
    # PluginRuntime::ManagedDriver catches that the same way it catches a
    # broken service_spec, reporting the plugin as "error" without attempting
    # to create a container. That is the entire gate on "enabling without an
    # auth key does nothing."
    #
    # Only ever the three keys the runtime manager's privileged lane allows
    # for this service. There is deliberately no way to pass an arbitrary
    # extra `tailscale up` flag through here -- the manager would refuse it.
    def self.privileged_env
      auth_key = Syrus::PluginSettings.get("tailscale", "auth_key").presence
      raise "TS_AUTHKEY is not configured" unless auth_key

      env = { "TS_AUTHKEY" => auth_key }
      hostname = Syrus::PluginSettings.get("tailscale", "hostname").presence
      env["TS_HOSTNAME"] = hostname if hostname
      env["TS_EXIT_NODE"] = "true" if ActiveModel::Type::Boolean.new.cast(Syrus::PluginSettings.get("tailscale", "exit_node"))
      env
    end
  end
end
