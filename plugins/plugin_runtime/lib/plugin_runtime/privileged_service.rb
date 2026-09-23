module PluginRuntime
  # The contract for a *first-party* privileged service, contributed through
  # "plugin_runtime:privileged_service" rather than the generic
  # "plugin_runtime:service" point Service documents.
  #
  # Unlike Service, contributing this point is not by itself enough to get a
  # container: DesiredPrivilegedServices only ever collects it from a plugin
  # named in its own FIRST_PARTY_PRIVILEGED_PLUGINS constant, and even then the
  # runtime manager's compiled internal/privileged.Registry (Go) has to agree
  # the name is a known privileged service before it creates anything. Two
  # independently-maintained allowlists, neither derived from the other, so a
  # mistake in either one alone fails closed. See
  # docs/plans/tailscale-privileged-service-lane.md.
  #
  #   module Tailscale
  #     class RuntimeService
  #       def self.privileged_service_name = "tailscale"
  #
  #       # Evaluated on every reconcile. Only ever the handful of settings the
  #       # runtime manager's compiled Definition allows for this service (see
  #       # internal/privileged.TailscaleAllowedEnvKeys) -- there is no "extra
  #       # flags" field to fill in here, because the manager would refuse it.
  #       def self.privileged_env
  #         { "TS_AUTHKEY" => Syrus::PluginSettings.get("tailscale", "auth_key") }
  #       end
  #     end
  #   end
  #
  # and reaches it exactly like any other service:
  #
  #   PluginRuntime::Services.endpoint_for("tailscale")  # => "http://tailscale:8080" or nil
  #
  # Image, internal port, capabilities, devices, and volumes are never part of
  # this contract -- they are fixed in the Go manager's compiled Definition,
  # not something a Ruby provider can express even if it tried.
  #
  # Contributors duck-type this module rather than including it, for the same
  # load-order reason Service documents.
  module PrivilegedService
    REQUIRED_METHODS = %i[privileged_service_name privileged_env].freeze

    def self.implemented_by?(provider)
      REQUIRED_METHODS.all? { |method| provider.respond_to?(method) }
    end
  end
end
