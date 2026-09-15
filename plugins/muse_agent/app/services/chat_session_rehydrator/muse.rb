require "json"

class ChatSessionRehydrator::Muse
  def initialize(chat_session, session_id: nil, cwd: nil, messages: nil)
    @chat_session = chat_session
    @session_id = session_id || chat_session.provider_session&.session_id
    @cwd = cwd
    @messages = messages
  end

  def call
    lines = []
    lines << event("run.session.created", session_payload) if @session_id.present?
    lines.concat(conversation_events)
    lines.map { |obj| JSON.generate(obj) }.join("\n") + "\n"
  end

  private

  def conversation_events
    messages_in_order.filter_map do |message|
      case message.role
      when "user"
        text_event("turn.input.user", text_content(message), timestamp: message.created_at)
      when "assistant"
        text_event("assistant.message", assistant_text(message), timestamp: message.created_at)
      when "tool_use"
        event("tool.call", tool_call_payload(message), timestamp: message.created_at)
      when "tool_result"
        event("tool.result", tool_result_payload(message), timestamp: message.created_at)
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

  def session_payload
    {
      "session_id" => @session_id,
      "cwd" => @cwd
    }.compact
  end

  def text_event(payload_type, text, timestamp:)
    return if text.blank?

    event(payload_type, { "text" => text }, timestamp: timestamp)
  end

  def tool_call_payload(message)
    name = tool_name(message)
    server, tool = split_server_tool(name)
    {
      "id" => message.tool_use_id.to_s.presence,
      "server" => server,
      "name" => tool,
      "input" => tool_input(message)
    }.compact
  end

  def tool_result_payload(message)
    {
      "id" => message.tool_use_id.to_s.presence,
      "name" => message.tool_name.to_s.presence,
      "content" => tool_result_content(message),
      "is_error" => tool_result_error?(message)
    }.compact
  end

  def event(payload_type, payload, timestamp: Time.current)
    {
      "record_type" => "event",
      "type" => "event",
      "payload_type" => payload_type,
      "timestamp" => timestamp&.iso8601,
      "payload" => payload
    }.compact
  end

  def text_content(message)
    message.content["text"].to_s
  end

  def assistant_text(message)
    if message.canonical_content_format?
      Array(message.content).filter_map { |block| block["text"] if block["type"] == "text" }.join
    else
      text_content(message)
    end
  end

  def tool_name(message)
    message.canonical_content_format? ? message.content["name"].to_s : message.tool_name.to_s
  end

  def tool_input(message)
    message.content["input"] || {}
  end

  def tool_result_content(message)
    message.canonical_content_format? ? message.content["content"] : message.content["result"]
  end

  def tool_result_error?(message)
    message.content["is_error"] == true
  end

  def split_server_tool(name)
    index = name.index(".")
    index ? [ name[0...index], name[(index + 1)..] ] : [ nil, name ]
  end
end
