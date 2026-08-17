# Server-Sent-Events streaming for chat turns, extracted from
# Api::V1::App::ChatsController.
#
# When a client requests text/event-stream, `stream_chat_turn` streams the
# user echo, then polls for the agent's response messages and emits them as
# SSE frames until the turn completes or times out. These run in the
# controller instance (ActionController::Live), reading request/response and
# the chat session's messages; they hold no per-user scoping of their own, so
# they mix straight back in. Kept private on include.
module ChatTurnStreaming
  private

  CHAT_STREAM_POLL_INTERVAL = 0.25.seconds
  CHAT_STREAM_TIMEOUT = 30.minutes

  def stream_request?
    request.format == Mime[:event_stream] || request.headers["Accept"].to_s.include?("text/event-stream")
  end

  def stream_chat_turn(chat_session, user_message, turn_enqueued: true)
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    self.response_body = Enumerator.new do |stream|
      write_sse(stream, "message", { role: "user", content: user_message.content["text"].to_s, message: chat_message_json(user_message, chat_session: chat_session) })
      if turn_enqueued
        stream_chat_messages(stream, chat_session, after_id: user_message.id)
      else
        write_sse(stream, "turn_complete", { chat_id: chat_session.id })
      end
    rescue StandardError => e
      write_sse(stream, "error", { message: e.message })
    end
  end

  def stream_chat_messages(stream, chat_session, after_id:)
    deadline = Time.current + CHAT_STREAM_TIMEOUT
    last_seen_id = after_id
    observed_turn_response = false

    loop do
      messages = chat_session.messages
        .includes(:pending_action, proposal: [ :repository, :job, :epic, :target_epic, dependencies: [], child_proposals: [ :repository, dependencies: [] ] ])
        .where("id > ?", last_seen_id)
        .order(:id)
        .to_a

      messages.each do |message|
        last_seen_id = message.id
        next if message.role == "user"

        observed_turn_response = true
        write_chat_stream_message(stream, message, chat_session: chat_session)
      end

      chat_session.reload
      if observed_turn_response && !chat_session.turn_in_flight? && !chat_session.agent_busy?
        write_sse(stream, "turn_complete", { chat_id: chat_session.id })
        break
      end

      if Time.current >= deadline
        write_sse(stream, "error", { message: "Chat turn timed out while waiting for the agent response." })
        break
      end

      sleep CHAT_STREAM_POLL_INTERVAL
    end
  end

  def write_chat_stream_message(stream, message, chat_session:)
    payload = chat_message_json(message, chat_session: chat_session)
    case message.role
    when "assistant"
      write_sse(stream, "text_chunk", { content: payload[:text], message: payload })
      write_sse(stream, "proposal", { proposal: payload[:proposal], message: payload }) if payload[:proposal]
    when "system"
      write_sse(stream, "error", { message: payload[:text], message_record: payload })
    else
      write_sse(stream, "message", { message: payload })
    end
  end

  def chat_message_json(message, chat_session:)
    ::App::ChatMessagePayload.messages([ message ], repository: chat_session.repository).first
  end

  def write_sse(stream, event, data)
    stream << "event: #{event}\n"
    stream << "data: #{JSON.generate(data)}\n\n"
  end
end
