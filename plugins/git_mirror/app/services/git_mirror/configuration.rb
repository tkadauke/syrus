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

    # The image matches the running Syrus build, so the service and the
    # plugin talking to it always come from the same commit. Development
    # builds have no published image of their own and use latest.
    def image
      ENV["SYRUS_GIT_MIRROR_IMAGE"].presence || "#{IMAGE_REPOSITORY}:#{image_tag}"
    end

    def image_tag
      version = SyrusVersion.current
      version.blank? || version == "dev" ? "latest" : version
    end
  end
end
