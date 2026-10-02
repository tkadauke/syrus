module WhisperStt
  # Deployment facts for the whisper.cpp daemon service. Plugin Runtime reads
  # this through RuntimeService; the speech-to-text provider added later will
  # resolve the running endpoint by service name.
  module Configuration
    SERVICE_NAME = "whisper-stt".freeze
    IMAGE_REPOSITORY = "ghcr.io/tkadauke/syrus-plugin-whisper-stt".freeze
    HEALTH_PATH = "/health".freeze

    module_function

    # Plugin images are published with the same tags as the backend image
    # (bin/publish-plugin-images), so a release runs the daemon from its own
    # release. Builds without a release version -- development, unversioned
    # publishes -- use latest.
    def image
      ENV["SYRUS_WHISPER_STT_IMAGE"].presence || "#{IMAGE_REPOSITORY}:#{image_tag}"
    end

    def image_tag
      ENV["SYRUS_VERSION"].presence || "latest"
    end
  end
end
