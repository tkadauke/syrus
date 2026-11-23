module ChatSpeechToText
  module Providers
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
