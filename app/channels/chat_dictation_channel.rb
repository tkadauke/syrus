class ChatDictationChannel < ApplicationCable::Channel
  TIMEOUT_POLL_INTERVAL = 5.seconds

  def subscribed
    return reject unless Feature.chat_speech_to_text_enabled?

    @chat_session = current_user.chat_sessions.find_by(id: params[:chat_session_id])
    return reject unless @chat_session

    @capability = ChatSpeechToText::Capability.for(user: current_user)
    return reject unless @capability.backend_streaming_available?

    @provider = @capability.backend_provider
    @sequence = 0
    @started_at = nil
    start_timeout_thread
  end

  def unsubscribed
    stop_timeout_thread
    @session&.cancel(reason: "unsubscribed")
  end

  def receive(data)
    case data["type"]
    when "start"
      start_session(data)
    when "audio_chunk"
      accept_audio_chunk(data)
    when "stop"
      finish_session
    when "cancel"
      cancel_session
    end
  end

  private

  def start_session(data)
    return transmit_failure("already_started", "Dictation session already started.") if @session

    content_type = normalized_content_type(data["content_type"])
    unless ChatSpeechToText::AudioConstraints::ALLOWED_CONTENT_TYPES.include?(content_type)
      transmit_failure("unsupported_content_type", "Stream a supported audio type.")
      return
    end

    @session = ChatSpeechToText::StreamingSession.new(
      chat_session: @chat_session,
      provider: @provider,
      content_type: content_type,
      language: data["language"].presence,
      prompt: data["prompt"].presence
    )
    @started_at = ChatSpeechToText::Telemetry.monotonic_time
    @session.start(
      on_delta: ->(delta) { transmit_delta(delta) },
      on_error: ->(error) { transmit_failure("speech_to_text_stream_failed", error.message.presence || "Backend streaming transcription failed.") },
      on_complete: ->(payload = {}) {
        ChatSpeechToText::Telemetry.log(
          "transcribed",
          chat_id: @chat_session.id,
          mode: "backend_streaming",
          provider: ChatSpeechToText::Telemetry.provider_name(@provider),
          duration_ms: @started_at ? ChatSpeechToText::Telemetry.duration_ms(@started_at) : nil
        )
        transmit_event("done", payload)
      }
    )
    ChatSpeechToText::Telemetry.log(
      "mode_selected",
      chat_id: @chat_session.id,
      mode: "backend_streaming",
      provider: ChatSpeechToText::Telemetry.provider_name(@provider),
      content_type: content_type
    )
    transmit_event("started", {
      session_id: @session.id,
      transport: "action_cable",
      fallback: fallback_payload
    })
  rescue ChatSpeechToText::Providers::TranscriptionError => e
    ChatSpeechToText::Telemetry.log(
      "error",
      chat_id: @chat_session.id,
      mode: "backend_streaming",
      **ChatSpeechToText::Telemetry.safe_error(e)
    )
    transmit_failure("speech_to_text_stream_failed", e.message)
  end

  def accept_audio_chunk(data)
    return transmit_failure("not_started", "Start a dictation session before streaming audio.") unless @session

    @session.accept_chunk(
      sequence: data["sequence"],
      audio_base64: data["audio"]
    )
    transmit_event("ack", { chunk_sequence: data["sequence"].to_i })
  rescue ChatSpeechToText::Providers::TranscriptionError => e
    @session&.mark_failed(e)
  end

  def finish_session
    return transmit_failure("not_started", "Start a dictation session before stopping it.") unless @session

    @session.finish
  rescue ChatSpeechToText::Providers::TranscriptionError => e
    @session&.mark_failed(e)
  end

  def cancel_session
    @session&.cancel(reason: "cancelled")
    transmit_event("cancelled", {})
  end

  def transmit_delta(delta)
    transmit_event("transcript_delta", {
      text: delta.text.to_s,
      final: !!delta.final,
      confidence: delta.confidence
    })
  end

  def transmit_failure(code, message)
    ChatSpeechToText::Telemetry.log(
      "fallback",
      chat_id: @chat_session.id,
      requested_mode: "backend_streaming",
      fallback_mode: "backend_batch",
      reason: code
    )
    transmit_event("error", {
      code: code,
      message: message,
      fallback: fallback_payload
    })
  end

  def transmit_event(type, payload)
    @sequence += 1
    transmit({
      "type" => type,
      "session_id" => @session&.id,
      "sequence" => @sequence
    }.merge(payload.deep_stringify_keys))
  end

  def fallback_payload
    {
      "mode" => "backend_batch",
      "buffered_audio_required" => true,
      "endpoint" => "/api/v1/app/chats/#{@chat_session.id}/speech_to_text"
    }
  end

  def normalized_content_type(content_type)
    content_type.to_s.split(";", 2).first.to_s.downcase
  end

  def start_timeout_thread
    @timeout_thread = Thread.new do
      loop do
        sleep TIMEOUT_POLL_INTERVAL
        next unless @session&.timed_out?

        @session.cancel(reason: "timeout")
        transmit_failure("speech_to_text_stream_timeout", "Backend streaming transcription timed out.")
        break
      rescue => e
        Rails.logger.error("ChatDictationChannel timeout error: #{e.message}")
        break
      end
    end
  end

  def stop_timeout_thread
    @timeout_thread&.kill
  end
end
