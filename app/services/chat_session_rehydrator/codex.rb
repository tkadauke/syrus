require "json"

# Reads a ChatSession's ChatMessage rows (in canonical Anthropic content-blocks
# format) and produces Codex JSONL — the thread.started / item.started /
# item.completed / turn.completed event stream Codex writes to its sessions
# directory and reads back on `codex exec resume`.
#
# Differences from the Claude rehydrator:
#   - Thinking blocks are dropped (Codex has no persistent reasoning state).
#   - bash tool_use rows map back to command_execution item events.
#   - Other tool_use rows map to mcp_tool_call item events; the dot-joined
#     "server.tool" name stored in ChatMessage is split back into separate
#     server / tool fields.
#   - User ChatMessage rows are omitted; the Codex resume command takes the
#     new user prompt directly and does not replay prior turns from the JSONL.
class ChatSessionRehydrator::Codex
  BASH_TOOL_NAME = "bash"

  def initialize(chat_session, session_id: nil, cwd: nil, messages: nil)
    @chat_session = chat_session
    @session_id   = session_id || chat_session.claude_session&.session_id
    @messages     = messages
  end

  # Returns JSONL string (one JSON object per line, trailing newline).
  def call
    lines = []
    lines << thread_started_event if @session_id.present?
    lines.concat(conversation_events)
    lines << { "type" => "turn.completed", "timestamp" => Time.current.iso8601 }
    lines.map { |obj| JSON.generate(obj) }.join("\n") + "\n"
  end

  private

  def thread_started_event
    {
      "type"      => "thread.started",
      "thread_id" => @session_id,
      "timestamp" => Time.current.iso8601
    }
  end

  def conversation_events
    events = []
    # Maps tool_use_id → metadata captured from the tool_use row, so the
    # paired tool_result row can emit item.completed with matching server/tool
    # or command info.
    pending_tool_uses = {}

    messages_in_order.each do |msg|
      case msg.role
      when "user", "system"
        # User prompts are passed directly to codex exec; system messages are
        # Syrus status messages. Neither appears in the Codex rollout JSONL.

      when "assistant"
        blocks = text_blocks_from_assistant(msg)
        text   = blocks.map { |b| b["text"].to_s }.join
        next if text.blank?

        id = msg.id.to_s
        ts = msg.created_at&.iso8601 || Time.current.iso8601
        events << {
          "type"      => "item.completed",
          "id"        => id,
          "timestamp" => ts,
          "item"      => { "type" => "agent_message", "id" => id, "text" => text, "status" => "completed" }
        }

      when "tool_use"
        name   = canonical_name(msg)
        id     = msg.tool_use_id.to_s
        ts     = msg.created_at&.iso8601 || Time.current.iso8601

        if name == BASH_TOOL_NAME
          command = canonical_input(msg)["command"].to_s
          pending_tool_uses[id] = { type: :bash, command: command }
          events << {
            "type"      => "item.started",
            "id"        => id,
            "timestamp" => ts,
            "item"      => { "type" => "command_execution", "call_id" => id, "command" => command }
          }
        else
          server, tool = split_server_tool(name)
          arguments    = canonical_input(msg)
          pending_tool_uses[id] = { type: :mcp, server: server, tool: tool }
          item = { "type" => "mcp_tool_call", "call_id" => id, "server" => server, "tool" => tool, "arguments" => arguments }
          item.compact!
          events << { "type" => "item.started", "id" => id, "timestamp" => ts, "item" => item }
        end

      when "tool_result"
        id      = msg.tool_use_id.to_s
        ts      = msg.created_at&.iso8601 || Time.current.iso8601
        pending = pending_tool_uses.delete(id)
        content = canonical_content(msg)
        error   = canonical_error?(msg)

        if pending&.fetch(:type) == :bash
          item = {
            "type"     => "command_execution",
            "call_id"  => id,
            "command"  => pending[:command],
            "status"   => error ? "failed" : "completed"
          }
          item[error ? "error" : "output"] = content
          events << { "type" => "item.completed", "id" => id, "timestamp" => ts, "item" => item }
        else
          item = {
            "type"    => "mcp_tool_call",
            "call_id" => id,
            "server"  => pending&.fetch(:server, nil),
            "tool"    => pending&.fetch(:tool, nil),
            "status"  => error ? "failed" : "completed"
          }
          item.compact!
          item[error ? "error" : "result"] = content
          events << { "type" => "item.completed", "id" => id, "timestamp" => ts, "item" => item }
        end
      end
    end

    events
  end

  def messages_in_order
    return @messages if @messages

    @chat_session.messages.order(:id)
  end

  # Returns only the text blocks from an assistant ChatMessage, dropping
  # thinking blocks (Codex has no persistent reasoning state to restore).
  def text_blocks_from_assistant(msg)
    if msg.canonical_content_format?
      Array(msg.content).select { |b| b["type"] == "text" }
    else
      text = msg.content["text"].to_s
      text.blank? ? [] : [ { "type" => "text", "text" => text } ]
    end
  end

  def canonical_name(msg)
    msg.canonical_content_format? ? msg.content["name"].to_s : msg.tool_name.to_s
  end

  def canonical_input(msg)
    msg.content["input"] || {}
  end

  def canonical_content(msg)
    msg.canonical_content_format? ? msg.content["content"] : msg.content["result"]
  end

  def canonical_error?(msg)
    msg.content["is_error"] == true
  end

  # "server.tool" → ["server", "tool"]
  # "toolonly"    → [nil, "toolonly"]
  # Splits on the first "." since server names use dashes, not dots.
  def split_server_tool(name)
    idx = name.index(".")
    idx ? [ name[0...idx], name[(idx + 1)..] ] : [ nil, name ]
  end
end
