module Syrus
  module Plugin
    # Interface for `:speech_to_text_provider` extension points: plugins that
    # can transcribe chat dictation audio. Core resolves providers through
    # ChatSpeechToText::Providers and never names a particular backend.
    #
    # Class methods (required):
    #
    #   provider_key                  -> String, stable identifier
    #   display_name                  -> String
    #   available?                    -> Boolean. Must be cheap and must not
    #                                    touch the network: capability checks
    #                                    call it during requests.
    #   build(user:)                  -> a ChatSpeechToText::Providers::Base
    #                                    instance, or nil when it cannot serve
    #                                    right now.
    #
    # Instances implement ChatSpeechToText::Providers::Base (`batch?`,
    # `streaming?`, `transcribe_batch`, `stream_transcription`). This module is
    # only the class-level plugin discovery contract.
    #
    # Register an implementation at boot time:
    #   provides speech_to_text_provider: "MyPlugin::SpeechToTextProvider"
    module SpeechToTextProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def provider_key
          raise NotImplementedError, "#{name} must implement .provider_key"
        end

        def display_name
          raise NotImplementedError, "#{name} must implement .display_name"
        end

        def available?
          raise NotImplementedError, "#{name} must implement .available?"
        end

        def build(user:)
          raise NotImplementedError, "#{name} must implement .build"
        end
      end
    end
  end
end
