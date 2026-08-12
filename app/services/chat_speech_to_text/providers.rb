module ChatSpeechToText
  module Providers
    REGISTRY = {
      "whisper_cpp" => WhisperCpp
    }.freeze

    DEFAULT_PROVIDER = "whisper_cpp"

    def self.configured
      provider_name = ENV["SYRUS_STT_PROVIDER"].to_s.strip.presence || DEFAULT_PROVIDER
      REGISTRY[provider_name]&.from_env
    end
  end
end
