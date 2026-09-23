module SyrusBrowser
  # Where the optional Browser Plugin Runtime service lives, if Plugin
  # Runtime is enabled and one is registered and healthy, plus the
  # deployment facts SyrusBrowser::RuntimeService hands the runtime manager
  # for it. See docs/syrus_docs/browser.md for the full service boundary
  # contract.
  #
  # `endpoint` answers nil until a service is registered and passes its
  # health check -- disabled Plugin Runtime, a service still pulling or
  # unhealthy, or (before this container existed) simply no provider at
  # all. Session.spawn falls back to the bundled stdio subprocess in every
  # one of those cases, so nothing here needs to change as the service comes
  # online; PluginRuntime::Services.endpoint_for just starts answering an
  # address.
  module Configuration
    SERVICE_NAME = "browser".freeze
    IMAGE_REPOSITORY = "ghcr.io/tkadauke/syrus-plugin-browser".freeze
    HEALTH_PATH = "/healthz".freeze

    def self.endpoint
      PluginRuntime::Services.endpoint_for(SERVICE_NAME)
    end

    # Plugin images are published with the same tags as the backend image
    # (bin/publish-plugin-images), so a release runs the service from its own
    # release. Builds without a release version -- development, unversioned
    # publishes -- use latest.
    def self.image
      ENV["SYRUS_BROWSER_IMAGE"].presence || "#{IMAGE_REPOSITORY}:#{image_tag}"
    end

    def self.image_tag
      ENV["SYRUS_VERSION"].presence || "latest"
    end
  end
end
