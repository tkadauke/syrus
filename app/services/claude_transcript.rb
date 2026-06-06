require "json"

# Parses a captured agent-session transcript_jsonl into a flat,
# UI-renderable list of events. The on-disk JSONL originated as claude-code's
# internal schema (NOT stream-json) and includes a lot of meta
# events (queue-operation, attachment, last-prompt, ai-title, …)
# that aren't directly useful to a human reader. This class extracts
# the events that matter for "what did the agent actually do?":
# session init (model + tools available), user prompts, assistant
# text, tool_use calls, tool_result responses, and the final
# result summary.
#
# Used by the admin transcript APIs to render the transcript viewer.
class ClaudeTranscript
  Event = Data.define(:kind, :timestamp, :data)
  # `kind` is one of:
  #   :system_init      — session start; data carries model, cwd, tools[]
  #   :user_prompt      — operator/system prompt to the agent
  #   :assistant_text   — agent's text response
  #   :tool_use         — agent invoked a tool; data has name, input, id
  #   :tool_result      — response to a tool_use; data has tool_use_id, content, error
  #   :result           — terminal event; data has turns, cost_usd, etc.
  #   :job_log          — fallback JobLog row when provider JSONL is absent/truncated
  #   :other            — anything we don't render specifically; kept for completeness

  Summary = Data.define(:total_turns, :total_tool_calls, :total_cost_usd,
                        :exit_reason, :tool_call_counts, :mcp_tool_called,
                        :available_tools_at_init, :session_id, :model, :cwd) do
    def mcp_tool_called? = mcp_tool_called
  end

  def initialize(jsonl)
    @jsonl = jsonl.to_s
  end

  # Yield every interesting event in order. A single JSONL line
  # can produce multiple events (an assistant turn with text +
  # tool_use yields two; a user turn with multiple tool_results
  # yields one per result), so callers should stream-iterate
  # rather than materialize the full list unless small.
  def events
    return enum_for(:events) unless block_given?
    @jsonl.each_line do |line|
      parse_line(line).each { |ev| yield ev }
    end
  end

  def summary
    @summary ||= compute_summary
  end

  private

  def parse_line(line)
    line = line.strip
    return [] if line.empty?
    parsed = JSON.parse(line)
    return [] unless parsed.is_a?(Hash)

    case parsed["type"]
    when "system"      then [ system_event(parsed) ].compact
    when "user"        then user_events(parsed)
    when "assistant"   then assistant_events(parsed)
    when "result"      then [ result_event(parsed) ]
    when "session_meta" then [ codex_session_event(parsed) ]
    when "event_msg"    then codex_event_events(parsed)
    when "response_item" then codex_response_item_events(parsed)
    when "thread.started" then [ codex_thread_started_event(parsed) ]
    when "turn.completed" then [ codex_turn_completed_event(parsed) ]
    when "turn.failed", "error" then [ codex_error_result_event(parsed) ]
    when "item.started", "item.completed" then codex_item_events(parsed)
    else                    [ Event.new(kind: :other, timestamp: parsed["timestamp"], data: parsed) ]
    end
  rescue JSON::ParserError, NoMethodError, TypeError
    []
  end

  # Claude-code wraps a session_id and (optionally) tool list in
  # `system` events with subtype `init`. Older / different shapes
  # may put the same info elsewhere; degrade gracefully.
  def system_event(parsed)
    if parsed["subtype"] == "init"
      Event.new(
        kind: :system_init,
        timestamp: parsed["timestamp"],
        data: {
          model: parsed["model"],
          cwd: parsed["cwd"],
          tools: parsed["tools"] || [],
          session_id: parsed["session_id"]
        }
      )
    else
      Event.new(kind: :other, timestamp: parsed["timestamp"], data: parsed)
    end
  end

  # `user` events carry either the operator's prompt (string content)
  # or `tool_result` blocks (array content). String → user_prompt.
  # Array → one tool_result event per block.
  def user_events(parsed)
    content = parsed.dig("message", "content")
    timestamp = parsed["timestamp"]

    if content.is_a?(String)
      [ Event.new(kind: :user_prompt, timestamp: timestamp, data: { text: content }) ]
    elsif content.is_a?(Array)
      content.filter_map do |c|
        next unless c["type"] == "tool_result"
        Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: c["tool_use_id"],
            content: c["content"],
            error: c["is_error"] == true
          }
        )
      end
    else
      [ Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
    end
  end

  # `assistant` events have a content array mixing text and
  # tool_use entries. Yield each block as its own event in order.
  def assistant_events(parsed)
    content = parsed.dig("message", "content") || []
    timestamp = parsed["timestamp"]
    content.filter_map do |block|
      case block["type"]
      when "text"
        Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: block["text"] })
      when "tool_use"
        Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: { name: block["name"], input: block["input"], id: block["id"] }
        )
      end
    end
  end

  def result_event(parsed)
    Event.new(
      kind: :result,
      timestamp: parsed["timestamp"],
      data: {
        turns: parsed["num_turns"],
        duration_ms: parsed["duration_ms"],
        cost_usd: parsed["total_cost_usd"],
        is_error: parsed["is_error"],
        subtype: parsed["subtype"],
        final_text: parsed["result"]
      }
    )
  end

  def codex_session_event(parsed)
    payload = parsed["payload"] || {}
    Event.new(
      kind: :system_init,
      timestamp: parsed["timestamp"] || payload["timestamp"],
      data: {
        model: payload["model"],
        cwd: payload["cwd"],
        tools: [],
        session_id: payload["id"]
      }
    )
  end

  def codex_event_events(parsed)
    payload = parsed["payload"] || {}
    timestamp = parsed["timestamp"]

    case payload["type"]
    when "user_message"
      [ Event.new(kind: :user_prompt, timestamp: timestamp, data: { text: payload["message"] }) ]
    when "agent_message"
      [ Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: payload["message"] }) ]
    when "mcp_tool_call_end"
      result = payload["result"]
      [ Event.new(
        kind: :tool_result,
        timestamp: timestamp,
        data: {
          tool_use_id: payload["call_id"],
          content: result,
          error: result.is_a?(Hash) && result.key?("Err")
        }
      ) ]
    when "task_complete"
      [ Event.new(
        kind: :result,
        timestamp: timestamp,
        data: {
          turns: nil,
          duration_ms: payload["duration_ms"],
          cost_usd: nil,
          is_error: false,
          subtype: "success",
          final_text: payload["last_agent_message"]
        }
      ) ]
    else
      [ Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
    end
  end

  def codex_response_item_events(parsed)
    payload = parsed["payload"] || {}
    timestamp = parsed["timestamp"]

    case payload["type"]
    when "message"
      content = payload["content"]
      text = if content.is_a?(Array)
        content.filter_map { |part| part["text"] || part.dig("content", 0, "text") }.join("\n")
      else
        content.to_s
      end
      return [] if text.blank?
      [ Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) ]
    when "function_call"
      name = [ payload["namespace"], payload["name"] ].compact.join
      input = JSON.parse(payload["arguments"].to_s) rescue payload["arguments"]
      [ Event.new(
        kind: :tool_use,
        timestamp: timestamp,
        data: { name: name, input: input, id: payload["call_id"] }
      ) ]
    when "function_call_output"
      [ Event.new(
        kind: :tool_result,
        timestamp: timestamp,
        data: { tool_use_id: payload["call_id"], content: payload["output"], error: false }
      ) ]
    else
      []
    end
  end

  def codex_thread_started_event(parsed)
    Event.new(
      kind: :system_init,
      timestamp: parsed["timestamp"],
      data: {
        model: parsed["model"],
        cwd: parsed["cwd"],
        tools: [],
        session_id: parsed["thread_id"] || parsed["session_id"]
      }
    )
  end

  def codex_turn_completed_event(parsed)
    usage = parsed["usage"] || {}
    Event.new(
      kind: :result,
      timestamp: parsed["timestamp"],
      data: {
        turns: 1,
        duration_ms: parsed["duration_ms"],
        cost_usd: nil,
        is_error: false,
        subtype: "success",
        final_text: parsed["final_text"] || parsed["last_agent_message"],
        usage: usage.presence
      }.compact
    )
  end

  def codex_error_result_event(parsed)
    Event.new(
      kind: :result,
      timestamp: parsed["timestamp"],
      data: {
        turns: nil,
        duration_ms: parsed["duration_ms"],
        cost_usd: nil,
        is_error: true,
        subtype: parsed["type"],
        final_text: parsed["error"] || parsed["message"] || "Codex run failed"
      }
    )
  end

  def codex_item_events(parsed)
    item = parsed["item"] || {}
    timestamp = parsed["timestamp"]
    status = item["status"] || parsed["type"].to_s.delete_prefix("item.")

    case item["type"]
    when "agent_message"
      text = item["text"].to_s
      return [] if text.blank?
      [ Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) ]
    when "mcp_tool_call"
      codex_mcp_tool_events(item, timestamp, status)
    when "command_execution"
      [ Event.new(
        kind: :tool_use,
        timestamp: timestamp,
        data: {
          name: "command_execution",
          input: { command: item["command"] }.compact,
          id: item["call_id"] || item["id"]
        }
      ) ]
    when "file_change"
      [ Event.new(
        kind: :system_event,
        timestamp: timestamp,
        data: { type: "file_change", path: item["path"], status: status }.compact
      ) ]
    else
      [ Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
    end
  end

  def codex_mcp_tool_events(item, timestamp, status)
    id = item["call_id"] || item["id"]
    name = codex_mcp_tool_name(item)
    if item["error"].present? || item["result"].present? || status == "completed"
      content = item["error"].presence || item["result"].presence || { status: status }
      [ Event.new(
        kind: :tool_result,
        timestamp: timestamp,
        data: {
          tool_use_id: id,
          content: content,
          error: item["error"].present?
        }
      ) ]
    else
      [ Event.new(
        kind: :tool_use,
        timestamp: timestamp,
        data: {
          name: name,
          input: item["arguments"] || item["input"] || {},
          id: id
        }
      ) ]
    end
  end

  def codex_mcp_tool_name(item)
    server = item["server"].presence || "mcp"
    tool = item["tool"].presence || item["name"].presence || "tool"
    "mcp__#{server}__#{tool}"
  end

  def compute_summary
    init = nil
    tool_calls = []
    cost_usd = nil
    turns = nil
    exit_reason = nil
    session_id = nil
    model = nil
    cwd = nil

    events do |ev|
      case ev.kind
      when :system_init
        init = ev.data
        session_id ||= ev.data[:session_id]
        model      ||= ev.data[:model]
        cwd        ||= ev.data[:cwd]
      when :tool_use
        tool_calls << ev.data[:name]
      when :result
        turns = ev.data[:turns]
        cost_usd = ev.data[:cost_usd]
        exit_reason = ev.data[:subtype]
      end
    end

    Summary.new(
      total_turns: turns,
      total_tool_calls: tool_calls.size,
      total_cost_usd: cost_usd,
      exit_reason: exit_reason,
      tool_call_counts: tool_calls.tally,
      mcp_tool_called: tool_calls.any? { |n| n.to_s.start_with?("mcp__") },
      available_tools_at_init: init&.dig(:tools) || [],
      session_id: session_id,
      model: model,
      cwd: cwd
    )
  end
end
