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
      backend_reason = backend_unavailable_reason
      {
        enabled: enabled?,
        backend: {
          configured: backend_provider.present?,
          unavailable_reason: backend_reason
        }.compact,
        modes: {
          backend_streaming: mode_json(backend_streaming_available?, backend_streaming_unavailable_reason),
          backend_batch: mode_json(backend_batch_available?, backend_batch_unavailable_reason),
          browser: { available: browser_fallback_available? }
        }
      }
    end

    private

    def mode_json(available, reason)
      { available: available, unavailable_reason: available ? nil : reason }.compact
    end

    def backend_unavailable_reason
      return "feature_disabled" unless enabled?
      return "provider_unset" unless backend_provider

      nil
    end

    def backend_streaming_unavailable_reason
      backend_unavailable_reason || (backend_streaming_available? ? nil : "provider_streaming_unavailable")
    end

    def backend_batch_unavailable_reason
      backend_unavailable_reason || (backend_batch_available? ? nil : "provider_batch_unavailable")
    end
  end
end
