require "json"

class ChatSessionRehydrator::Agy
  def initialize(chat_session, session_id: nil, cwd: nil, messages: nil)
    @chat_session = chat_session
    @session_id = session_id || chat_session.provider_session&.session_id
    @messages = messages
  end

  def call
    lines = []
    lines << init_event if @session_id.present?
    lines.concat(conversation_events)
    lines.map { |obj| JSON.generate(obj) }.join("\n") + "\n"
  end

  private

  def init_event
    {
      "event" => "init",
      "conversation_id" => @session_id,
      "timestamp" => Time.current.iso8601
    }
  end

  def conversation_events
    messages_in_order.filter_map do |message|
      case message.role
      when "user"
        user_event(message)
      when "assistant"
        assistant_event(message)
      when "tool_use"
        tool_call_event(message)
      when "tool_result"
        tool_result_event(message)
      end
    end
  end

  def messages_in_order
    return @messages if @messages

    if ChatContextCompactor.enabled_for?(@chat_session)
      return ChatContextCompactor.context_messages_for(@chat_session)
    end

    @chat_session.messages.order(:id)
  end

  def user_event(message)
    text = message.content["text"].to_s
    return if text.blank?

    with_timestamp(message, {
      "event" => "user",
      "message" => { "content" => text }
    })
  end

  def assistant_event(message)
    text = assistant_text(message)
    return if text.blank?

    with_timestamp(message, {
      "event" => "step_update",
      "message" => { "role" => "assistant", "content" => text }
    })
  end

  def tool_call_event(message)
    name = canonical_name(message)
    return if name.blank?

    with_timestamp(message, {
      "event" => "step_update",
      "type" => "tool_call",
      "tool_call" => {
        "id" => message.tool_use_id.to_s,
        "name" => agy_tool_name(name),
        "input" => canonical_input(message)
      }
    })
  end

  def tool_result_event(message)
    with_timestamp(message, {
      "event" => "step_update",
      "type" => "tool_result",
      "tool_result" => {
        "id" => message.tool_use_id.to_s,
        "name" => canonical_name(message).presence,
        "content" => canonical_content(message),
        "is_error" => canonical_error?(message)
      }.compact
    })
  end

  def with_timestamp(message, event)
    event["timestamp"] = message.created_at.iso8601 if message.created_at
    event
  end

  def assistant_text(message)
    if message.canonical_content_format?
      Array(message.content).filter_map { |block| block["text"] if block["type"] == "text" }.join
    else
      message.content["text"].to_s
    end
  end

  def canonical_name(message)
    message.canonical_content_format? ? message.content["name"].to_s : message.tool_name.to_s
  end

  def canonical_input(message)
    message.content["input"] || {}
  end

  def canonical_content(message)
    message.canonical_content_format? ? message.content["content"] : message.content["result"]
  end

  def canonical_error?(message)
    message.content["is_error"] == true
  end

  def agy_tool_name(name)
    if (match = name.match(/\Amcp__(.+?)__(.+)\z/))
      AgentProviders::Agy.mcp_tool_name(match[2], server_name: match[1])
    else
      name
    end
  end
end
