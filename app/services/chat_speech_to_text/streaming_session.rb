require "base64"
require "securerandom"

module ChatSpeechToText
  class StreamingSession
    MAX_CHUNK_BYTES = 512.kilobytes
    MAX_TOTAL_BYTES = AudioConstraints::MAX_BYTES
    IDLE_TIMEOUT = 30.seconds

    attr_reader :id, :chat_session, :content_type, :language, :prompt, :started_at, :last_activity_at

    def initialize(chat_session:, provider:, content_type:, language: nil, prompt: nil, id: SecureRandom.uuid, clock: -> { Time.current })
      @chat_session = chat_session
      @provider = provider
      @content_type = content_type
      @language = language
      @prompt = prompt
      @id = id
      @clock = clock
      @started_at = @clock.call
      @last_activity_at = @started_at
      @next_chunk_sequence = 1
      @total_bytes = 0
      @state = :initialized
    end

    def start(on_delta:, on_error:, on_complete:)
      raise Providers::TranscriptionError, "Dictation session already started." unless @state == :initialized

      @on_error = on_error
      @on_complete = on_complete
      @provider_stream = @provider.stream_transcription(
        Providers::StreamingRequest.new(
          content_type: content_type,
          language: language,
          prompt: prompt,
          on_delta: on_delta,
          on_error: ->(error) {
            @state = :failed
            on_error.call(error)
          },
          on_complete: ->(payload = {}) {
            @state = :completed
            on_complete.call(payload)
          }
        )
      )
      @state = :streaming
    end

    def accept_chunk(sequence:, audio_base64:)
      ensure_streaming!
      sequence = sequence.to_i
      unless sequence == @next_chunk_sequence
        raise Providers::TranscriptionError, "Audio chunks must arrive in order. Expected #{@next_chunk_sequence}, got #{sequence}."
      end

      audio = Base64.strict_decode64(audio_base64.to_s)
      if audio.bytesize > MAX_CHUNK_BYTES
        raise Providers::TranscriptionError, "Audio chunk is too large."
      end

      @total_bytes += audio.bytesize
      if @total_bytes > MAX_TOTAL_BYTES
        raise Providers::TranscriptionError, "Audio stream exceeded the 10 MB limit."
      end

      @provider_stream.accept_audio(audio)
      @next_chunk_sequence += 1
      touch
    rescue ArgumentError
      raise Providers::TranscriptionError, "Audio chunk is not valid base64."
    end

    def finish
      ensure_streaming!
      @state = :finishing
      @provider_stream.finish
      touch
    end

    def cancel(reason: "cancelled")
      return if terminal?

      @state = :cancelled
      @provider_stream&.cancel if @provider_stream&.respond_to?(:cancel)
    end

    def timed_out?
      !terminal? && @clock.call - last_activity_at > IDLE_TIMEOUT
    end

    def mark_failed(error)
      return if terminal?

      @state = :failed
      @provider_stream&.cancel if @provider_stream&.respond_to?(:cancel)
      @on_error&.call(error)
    end

    private

    def terminal?
      %i[completed cancelled failed].include?(@state)
    end

    def ensure_streaming!
      raise Providers::TranscriptionError, "Dictation session is not streaming." unless @state == :streaming
    end

    def touch
      @last_activity_at = @clock.call
    end
  end
end
