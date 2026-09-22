module GitMirror
  # Deployment facts for the mirror service. Environment, not plugin settings,
  # for the same reason PluginRuntime::Configuration uses it: the token is a
  # secret and the image is a property of the release.
  module Configuration
    SERVICE_NAME = "git-mirror".freeze
    IMAGE_REPOSITORY = "ghcr.io/tkadauke/syrus-plugin-git-mirror".freeze

    module_function

    # The bearer token Syrus and the mirror share. On Kubernetes, set
    # SYRUS_GIT_MIRROR_TOKEN on both. On Compose the plugin hands the service
    # its token itself, so by default it is derived from secret_key_base:
    # stable across restarts, never stored, and different per installation.
    def token
      ENV["SYRUS_GIT_MIRROR_TOKEN"].presence ||
        Rails.application.key_generator.generate_key("syrus.git_mirror.token", 32).unpack1("H*")
    end

    # Plugin images are published with the same tags as the backend image
    # (bin/publish-plugin-images), so a release runs the mirror from its own
    # release. Builds without a release version -- development, unversioned
    # publishes -- use latest.
    def image
      ENV["SYRUS_GIT_MIRROR_IMAGE"].presence || "#{IMAGE_REPOSITORY}:#{image_tag}"
    end

    def image_tag
      ENV["SYRUS_VERSION"].presence || "latest"
    end
  end
end
