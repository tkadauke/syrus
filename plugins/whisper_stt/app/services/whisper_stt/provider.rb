module WhisperStt
  class Provider < Syrus::Host::SpeechToTextBase
    include Syrus::Plugin::SpeechToTextProvider

    def self.provider_key = "whisper_stt"
    def self.display_name = "Whisper speech-to-text"
    def self.available? = PluginRuntime::Services.endpoint_for(RuntimeService.service_name).present?
    def self.build(user:) = available? ? new : nil

    def initialize(client: Client.new)
      @client = client
    end

    def batch?
      true
    end

    def streaming?
      return @streaming if defined?(@streaming)

      @streaming = client.streaming_available?
    end

    def stream_transcription(request)
      Stream.new(client: client, request: request)
    end

    def transcribe_batch(request)
      started_at = Syrus::Host::SpeechToTextTelemetry.monotonic_time
      response = client.transcribe(
        audio: request.audio,
        content_type: request.content_type,
        language: request.language,
        prompt: request.prompt,
        correlation_id: request.correlation_id
      )
      text = response.fetch("text", "").to_s.strip
      raise Syrus::Host::SpeechToTextError, "whisper.cpp returned an empty transcript" if text.blank?

      result = Syrus::Host::SpeechToTextResult.new(
        text: text,
        segments: response["segments"] || [],
        provider: self.class.provider_key,
        confidence: nil
      )
      Syrus::Host::SpeechToTextTelemetry.log(
        "transcribed",
        mode: "backend_batch",
        provider: self.class.provider_key,
        duration_ms: Syrus::Host::SpeechToTextTelemetry.duration_ms(started_at)
      )
      result
    rescue Client::TimeoutError => e
      raise transcription_error(e.message, started_at, Syrus::Host::SpeechToTextTimeout)
    rescue Client::Unavailable => e
      raise transcription_error(e.message, started_at, Syrus::Host::SpeechToTextUnavailable)
    rescue Client::InvalidInput => e
      raise transcription_error(e.message, started_at, Syrus::Host::SpeechToTextInvalidAudio)
    rescue Client::Error => e
      raise transcription_error(e.message.presence || "whisper.cpp transcription failed", started_at)
    rescue Syrus::Host::SpeechToTextError => e
      Syrus::Host::SpeechToTextTelemetry.log(
        "error",
        mode: "backend_batch",
        provider: self.class.provider_key,
        duration_ms: Syrus::Host::SpeechToTextTelemetry.duration_ms(started_at),
        **Syrus::Host::SpeechToTextTelemetry.safe_error(e)
      )
      raise
    end

    private

    attr_reader :client

    class Stream
      def initialize(client:, request:)
        @client = client
        @request = request
        @sequence = 0
        @closed = false
        @id = client.start_stream(content_type: request.content_type, language: request.language, prompt: request.prompt)
      rescue Client::Error => e
        raise Syrus::Host::SpeechToTextError, e.message
      end

      def accept_audio(audio)
        ensure_open!
        emit(client.append_stream(id: id, sequence: (@sequence += 1), audio: audio), final: false)
      rescue Client::Error => e
        fail_stream(e)
      end

      def finish
        ensure_open!
        payload = client.finish_stream(id: id)
        emit(payload, final: true)
        @closed = true
        request.on_complete.call(reason: "finalized")
      rescue Client::Error => e
        fail_stream(e)
      end

      def cancel
        return if @closed

        @closed = true
        client.cancel_stream(id: id)
      end

      private

      attr_reader :client, :id, :request

      def emit(payload, final:)
        text = payload["text"].to_s.strip
        return if text.blank?

        request.on_delta.call(Syrus::Host::SpeechToTextStreamingDelta.new(text: text, final: final, confidence: nil))
      end

      def ensure_open!
        raise Syrus::Host::SpeechToTextError, "Dictation stream is closed." if @closed
      end

      def fail_stream(error)
        @closed = true
        client.cancel_stream(id: id)
        translated = Syrus::Host::SpeechToTextError.new(error.message.presence || "whisper.cpp streaming transcription failed")
        request.on_error.call(translated)
        raise translated
      end
    end

    def transcription_error(message, started_at, error_class = Syrus::Host::SpeechToTextError)
      error_class.new(message).tap do |error|
        Syrus::Host::SpeechToTextTelemetry.log(
          "error",
          mode: "backend_batch",
          provider: self.class.provider_key,
          duration_ms: Syrus::Host::SpeechToTextTelemetry.duration_ms(started_at),
          **Syrus::Host::SpeechToTextTelemetry.safe_error(error)
        )
      end
    end
  end
end
