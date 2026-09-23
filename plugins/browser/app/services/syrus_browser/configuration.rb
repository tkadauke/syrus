module SyrusBrowser
  # Where the optional Browser Plugin Runtime service lives, if Plugin
  # Runtime is enabled and one is registered and healthy. See
  # docs/syrus_docs/browser.md for the full service boundary contract.
  #
  # This plugin does not yet contribute a "plugin_runtime:service" provider
  # (that is later work -- see the container-backed runtime epic), so
  # `endpoint` answers nil today regardless of deployment, and
  # Session.spawn always falls back to the bundled stdio subprocess. Once a
  # service exists, PluginRuntime::Services.endpoint_for starts answering an
  # address by itself; nothing here needs to change.
  module Configuration
    SERVICE_NAME = "browser".freeze

    def self.endpoint
      PluginRuntime::Services.endpoint_for(SERVICE_NAME)
    end
  end
end
