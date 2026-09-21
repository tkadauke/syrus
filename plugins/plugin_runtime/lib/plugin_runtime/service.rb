module PluginRuntime
  # The contract for a service contributed through the "plugin_runtime:service"
  # point. A container-backed plugin declares plugin_runtime as a hard
  # dependency, points "plugin_runtime:service" at a class, and that class
  # answers two methods. The manifest half of the example is in
  # docs/syrus_docs/plugin_runtime.md rather than here: the plugin boundary
  # audit reads dependency declarations out of lib/ by text, comments included,
  # so spelling one out in this comment registers a real self-dependency.
  #
  #   module GitMirror
  #     class RuntimeService
  #       # Stable DNS name on the project network, and the key everything else
  #       # is looked up by. Lowercase letters, digits and dashes.
  #       def self.service_name = "git-mirror"
  #
  #       # Evaluated on every reconcile, so env can carry values that change
  #       # -- a rotated secret, a new Syrus URL. A changed spec replaces the
  #       # container; its named volumes survive.
  #       def self.service_spec
  #         {
  #           image: "ghcr.io/tkadauke/syrus-plugin-git-mirror:#{SyrusVersion.revision}",
  #           internal_port: 8080,
  #           volumes: [ { name: "data", mount_path: "/data" } ],
  #           env: { "SYRUS_URL" => "http://web:3000" },
  #           healthcheck: { path: "/healthz" }
  #         }
  #       end
  #     end
  #   end
  #
  # and reaches it with:
  #
  #   PluginRuntime::Services.endpoint_for("git-mirror")  # => "http://git-mirror:8080" or nil
  #
  # nil means "not available right now" -- not yet pulled, starting, unhealthy,
  # or not configured -- and callers must have a way to carry on without it.
  # A service is an accelerator or an extra, never something the rest of Syrus
  # stops working without.
  #
  # The spec is validated by the runtime manager, not here: the manager is what
  # holds the Docker socket, so it is the only place a check actually binds.
  # See plugins/plugin_runtime/container/internal/policy for what it refuses.
  #
  # Contributors do not `include` this module. Doing so would make them load a
  # PluginRuntime constant at boot, turning a declared dependency into a
  # load-order one. It documents the contract; contributors duck-type it.
  module Service
    REQUIRED_METHODS = %i[service_name service_spec].freeze

    def self.implemented_by?(provider)
      REQUIRED_METHODS.all? { |method| provider.respond_to?(method) }
    end
  end
end
