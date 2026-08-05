module ChatSpeechToText
  Capability = Data.define(:feature_enabled, :backend_provider) do
    def self.for(user:)
      new(
        feature_enabled: Feature.chat_speech_to_text_enabled?,
        backend_provider: Providers.configured
      )
    end

    def enabled?
      feature_enabled
    end

    def backend_streaming_available?
      enabled? && !!backend_provider&.streaming?
    end

    def backend_batch_available?
      enabled? && !!backend_provider&.batch?
    end

    def browser_fallback_available?
      enabled?
    end

    def backend_available?
      backend_streaming_available? || backend_batch_available?
    end

    def as_json(*)
      {
        enabled: enabled?,
        modes: {
          backend_streaming: { available: backend_streaming_available? },
          backend_batch: { available: backend_batch_available? },
          browser: { available: browser_fallback_available? }
        }
      }
    end
  end
end
