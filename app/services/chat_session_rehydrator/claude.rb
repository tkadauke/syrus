require "json"

# Reads a ChatSession's ChatMessage rows (in canonical Anthropic content-blocks
# format) and produces Claude Code session JSONL — the same schema Claude Code
# writes to ~/.claude/projects/{encoded-cwd}/{session_id}.jsonl.
#
# Thinking blocks are preserved. Legacy flat-format rows are normalized to
# content-blocks on the fly so both old and new rows round-trip cleanly.
#
# The Claude JSONL format groups rows differently than the DB rows:
#   - An assistant ChatMessage + subsequent tool_use ChatMessages are merged
#     into one JSONL assistant event (Claude's API returns them in one response).
#   - Consecutive tool_result ChatMessages are merged into one JSONL user event
#     with an array content (Claude's API expects all results bundled).
class ChatSessionRehydrator::Claude
  def initialize(chat_session, session_id: nil, cwd: nil, model: nil, tools: nil)
    @chat_session = chat_session
    @session_id   = session_id || chat_session.claude_session&.session_id
    @cwd          = cwd
    @model        = model
    @tools        = tools
  end

  # Returns JSONL string (one JSON object per line, trailing newline).
  def call
    lines = []
    lines << system_init_event if @session_id.present?
    lines.concat(conversation_events)
    lines.map { |obj| JSON.generate(obj) }.join("\n") + "\n"
  end

  private

  def system_init_event
    event = { "type" => "system", "subtype" => "init" }
    event["session_id"] = @session_id
    event["cwd"]        = @cwd    if @cwd.present?
    event["model"]      = @model  if @model.present?
    event["tools"]      = @tools  unless @tools.nil?
    event
  end

  # Iterates over ChatMessage rows in insertion order, merging rows into the
  # multi-turn JSONL structure Claude Code expects.
  def conversation_events
    events = []
    pending_assistant = []   # content blocks accumulating for the current assistant JSONL event
    pending_assistant_ts = nil
    pending_tool_results = []  # tool_result blocks for the upcoming user JSONL event
    pending_tool_results_ts = nil

    @chat_session.messages.order(:id).each do |msg|
      case msg.role
      when "user"
        # Flush any buffered tool_results before emitting a new user prompt —
        # tool_result events become their own user JSONL line separate from text.
        if pending_tool_results.any?
          events << user_tool_results_event(pending_tool_results, pending_tool_results_ts)
          pending_tool_results = []
          pending_tool_results_ts = nil
        end
        # A pending assistant group without any following tool_use should be
        # flushed now (edge case: two consecutive assistant messages).
        if pending_assistant.any?
          events << assistant_event(pending_assistant, pending_assistant_ts)
          pending_assistant = []
          pending_assistant_ts = nil
        end
        text = msg.content["text"].to_s
        events << user_prompt_event(text, msg.created_at)

      when "assistant"
        if pending_tool_results.any?
          events << user_tool_results_event(pending_tool_results, pending_tool_results_ts)
          pending_tool_results = []
          pending_tool_results_ts = nil
        end
        if pending_assistant.any?
          events << assistant_event(pending_assistant, pending_assistant_ts)
          pending_assistant = []
          pending_assistant_ts = nil
        end
        blocks = assistant_content_blocks(msg)
        unless blocks.empty?
          pending_assistant.concat(blocks)
          pending_assistant_ts ||= msg.created_at
        end

      when "tool_use"
        # tool_use rows belong to the preceding assistant turn in the JSONL.
        block = tool_use_content_block(msg)
        pending_assistant << block
        pending_assistant_ts ||= msg.created_at

      when "tool_result"
        # Flush accumulated assistant content before emitting tool results.
        if pending_assistant.any?
          events << assistant_event(pending_assistant, pending_assistant_ts)
          pending_assistant = []
          pending_assistant_ts = nil
        end
        block = tool_result_content_block(msg)
        pending_tool_results << block
        pending_tool_results_ts ||= msg.created_at

      when "system"
        # Syrus status messages — not part of the agent conversation JSONL.
      end
    end

    # Flush anything remaining at end-of-session.
    if pending_assistant.any?
      events << assistant_event(pending_assistant, pending_assistant_ts)
    end
    if pending_tool_results.any?
      events << user_tool_results_event(pending_tool_results, pending_tool_results_ts)
    end

    events
  end

  def user_prompt_event(text, ts)
    event = { "type" => "user", "message" => { "role" => "user", "content" => text } }
    event["timestamp"] = ts.iso8601 if ts
    event
  end

  def user_tool_results_event(blocks, ts)
    event = { "type" => "user", "message" => { "role" => "user", "content" => blocks } }
    event["timestamp"] = ts.iso8601 if ts
    event
  end

  def assistant_event(blocks, ts)
    event = { "type" => "assistant", "message" => { "content" => blocks } }
    event["timestamp"] = ts.iso8601 if ts
    event
  end

  # Normalizes an assistant ChatMessage content to an array of content-blocks.
  # Legacy format: {"text" => "..."} → [{type: "text", text: "..."}]
  # Canonical format: already an array of blocks.
  def assistant_content_blocks(msg)
    if msg.canonical_content_format?
      Array(msg.content)
    else
      text = msg.content["text"].to_s
      text.empty? ? [] : [ { "type" => "text", "text" => text } ]
    end
  end

  # Normalizes a tool_use ChatMessage content to the tool_use content-block.
  # Legacy format: {"input" => {...}} → {type: "tool_use", id: ..., name: ..., input: ...}
  # Canonical format: already {type: "tool_use", id: ..., name: ..., input: ...}
  def tool_use_content_block(msg)
    if msg.canonical_content_format?
      msg.content
    else
      {
        "type"  => "tool_use",
        "id"    => msg.tool_use_id.to_s,
        "name"  => msg.tool_name.to_s,
        "input" => msg.content["input"] || {}
      }
    end
  end

  # Normalizes a tool_result ChatMessage content to the tool_result content-block.
  # Legacy format: {"result" => ..., "is_error" => bool}
  # Canonical format: {type: "tool_result", tool_use_id: ..., content: ..., is_error: bool}
  def tool_result_content_block(msg)
    if msg.canonical_content_format?
      msg.content
    else
      {
        "type"        => "tool_result",
        "tool_use_id" => msg.tool_use_id.to_s,
        "content"     => msg.content["result"],
        "is_error"    => msg.content["is_error"] == true
      }
    end
  end
end
