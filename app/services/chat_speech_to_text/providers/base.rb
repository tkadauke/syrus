module ChatSpeechToText
  module Providers
    TranscriptionRequest = Data.define(:audio, :content_type, :language, :prompt)
    TranscriptionResult = Data.define(:text, :segments, :provider, :confidence)
    StreamingRequest = Data.define(:content_type, :language, :prompt, :on_delta, :on_error, :on_complete)
    StreamingDelta = Data.define(:text, :final, :confidence)

    class TranscriptionError < StandardError; end

    class Base
      def streaming?
        false
      end

      def batch?
        false
      end

      def transcribe_batch(_request)
        raise NotImplementedError, "#{self.class.name} does not implement batch transcription"
      end

      def stream_transcription(_request)
        raise NotImplementedError, "#{self.class.name} does not implement streaming transcription"
      end
    end
  end
end
