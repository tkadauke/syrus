module ChatSpeechToText
  module Providers
    REGISTRY = {
      "whisper_cpp" => WhisperCpp
    }.freeze

    def self.configured
      provider_name = ENV["SYRUS_STT_PROVIDER"].to_s.strip
      REGISTRY[provider_name]&.from_env
    end
  end
end
