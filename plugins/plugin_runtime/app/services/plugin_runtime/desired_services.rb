module PluginRuntime
  # The services that should exist right now: one per enabled plugin that
  # contributes to "plugin_runtime:service".
  #
  # This reads the manifests directly rather than through
  # PluginRegistry.providers_for, because providers_for hands back bare
  # classes and the reconciler also needs to know which plugin owns each one
  # -- the runtime manager labels the container with it, so an operator
  # looking at `docker ps` can tell whose it is.
  #
  # Disabled plugins drop out of this set, which is the whole of how disabling
  # works: the reconciler removes any managed service no longer listed here.
  class DesiredServices
    extend DesiredServiceCollection

    POINT = "plugin_runtime:service".freeze

    Entry = DesiredServiceCollection::Entry

    def self.point = POINT
    def self.contract = Service
    def self.label = "service"
    def self.public_name_for(provider) = provider.service_name
  end
end
