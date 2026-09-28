module PluginRuntime
  # The privileged services that should exist right now: one per enabled
  # plugin that both contributes to "plugin_runtime:privileged_service" and is
  # named in FIRST_PARTY_PRIVILEGED_PLUGINS.
  #
  # That constant and the runtime manager's own compiled
  # internal/privileged.Registry (Go) are two independently-maintained
  # allowlists that do not derive from one another: a stray manifest
  # declaration here does nothing unless the Go binary also has a compiled
  # Definition for the same name, and a name missing from this constant is
  # never even attempted, whatever the manifest says. Either mistake fails
  # closed. See docs/plans/tailscale-privileged-service-lane.md.
  #
  # Disabled plugins drop out of this set the same way DesiredServices works:
  # the reconciler removes any managed privileged service no longer listed.
  class DesiredPrivilegedServices
    extend DesiredServiceCollection

    POINT = "plugin_runtime:privileged_service".freeze

    # The only plugins allowed to reach the privileged lane at all. Adding a
    # second entry here is a Plugin Runtime change, reviewed as one -- never
    # something a plugin's own manifest can opt into.
    FIRST_PARTY_PRIVILEGED_PLUGINS = %w[tailscale].freeze

    Entry = DesiredServiceCollection::Entry

    def self.point = POINT
    def self.contract = PrivilegedService
    def self.label = "privileged service"
    def self.public_name_for(provider) = provider.privileged_service_name
    def self.eligible_manifest?(manifest) = FIRST_PARTY_PRIVILEGED_PLUGINS.include?(manifest.name)
  end
end
