module ChatSpeechToText
  module Providers
    TranscriptionRequest = Data.define(:audio, :content_type, :language, :prompt, :correlation_id)
    TranscriptionResult = Data.define(:text, :segments, :provider, :confidence)
    StreamingRequest = Data.define(:content_type, :language, :prompt, :on_delta, :on_error, :on_complete)
    StreamingDelta = Data.define(:text, :final, :confidence)

    class TranscriptionError < StandardError; end
    class InvalidAudio < TranscriptionError; end
    class TranscriptionTimeout < TranscriptionError; end
    class TranscriptionUnavailable < TranscriptionError; end

    def self.configured(user: nil)
      candidates = provider_classes.select(&:available?)
      pinned_provider_key = ENV["SYRUS_STT_PROVIDER"].to_s.strip.presence
      candidates = candidates.select { |provider| provider.provider_key == pinned_provider_key } if pinned_provider_key

      candidates.filter_map { |provider| provider.build(user: user) }.first
    end

    def self.provider_classes
      Syrus::Plugin::ServiceProvider.providers(:speech_to_text_provider).map do |provider|
        provider.is_a?(String) ? provider.constantize : provider
      end
    end
  end
end
