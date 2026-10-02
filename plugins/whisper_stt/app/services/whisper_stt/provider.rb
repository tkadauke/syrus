module WhisperStt
  class Provider < ChatSpeechToText::Providers::Base
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
      false
    end

    def transcribe_batch(request)
      started_at = ChatSpeechToText::Telemetry.monotonic_time
      response = client.transcribe(
        audio: request.audio,
        content_type: request.content_type,
        language: request.language,
        prompt: request.prompt
      )
      text = response.fetch("text", "").to_s.strip
      raise ChatSpeechToText::Providers::TranscriptionError, "whisper.cpp returned an empty transcript" if text.blank?

      result = ChatSpeechToText::Providers::TranscriptionResult.new(
        text: text,
        segments: response["segments"] || [],
        provider: self.class.provider_key,
        confidence: nil
      )
      ChatSpeechToText::Telemetry.log(
        "transcribed",
        mode: "backend_batch",
        provider: self.class.provider_key,
        duration_ms: ChatSpeechToText::Telemetry.duration_ms(started_at)
      )
      result
    rescue Client::TimeoutError => e
      raise transcription_error(e.message, started_at)
    rescue Client::Error => e
      raise transcription_error(e.message.presence || "whisper.cpp transcription failed", started_at)
    rescue ChatSpeechToText::Providers::TranscriptionError => e
      ChatSpeechToText::Telemetry.log(
        "error",
        mode: "backend_batch",
        provider: self.class.provider_key,
        duration_ms: ChatSpeechToText::Telemetry.duration_ms(started_at),
        **ChatSpeechToText::Telemetry.safe_error(e)
      )
      raise
    end

    private

    attr_reader :client

    def transcription_error(message, started_at)
      ChatSpeechToText::Providers::TranscriptionError.new(message).tap do |error|
        ChatSpeechToText::Telemetry.log(
          "error",
          mode: "backend_batch",
          provider: self.class.provider_key,
          duration_ms: ChatSpeechToText::Telemetry.duration_ms(started_at),
          **ChatSpeechToText::Telemetry.safe_error(error)
        )
      end
    end
  end
end
