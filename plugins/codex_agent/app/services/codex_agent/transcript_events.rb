module CodexAgent
  module TranscriptEvents
    def codex_session_event(parsed)
      payload = parsed["payload"] || {}
      ClaudeTranscript::Event.new(
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
        [ ClaudeTranscript::Event.new(kind: :user_prompt, timestamp: timestamp, data: { text: payload["message"] }) ]
      when "agent_message"
        [ ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: payload["message"] }) ]
      when "mcp_tool_call_end"
        result = payload["result"]
        name = codex_mcp_tool_name(payload)
        [ ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: payload["call_id"],
            name: name,
            content: result,
            error: result.is_a?(Hash) && result.key?("Err")
          }.compact
        ) ]
      when "task_complete"
        [ ClaudeTranscript::Event.new(
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
        [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
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
        [ ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) ]
      when "function_call"
        name = [ payload["namespace"], payload["name"] ].compact.join
        input = JSON.parse(payload["arguments"].to_s) rescue payload["arguments"]
        [ ClaudeTranscript::Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: { name: name, input: input, id: payload["call_id"] }
        ) ]
      when "function_call_output"
        [ ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: payload["call_id"],
            name: [ payload["namespace"], payload["name"] ].compact.join.presence,
            content: payload["output"],
            error: false
          }.compact
        ) ]
      else
        []
      end
    end

    def codex_thread_started_event(parsed)
      ClaudeTranscript::Event.new(
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
      ClaudeTranscript::Event.new(
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
      ClaudeTranscript::Event.new(
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
        [ ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) ]
      when "mcp_tool_call"
        codex_mcp_tool_events(item, timestamp, status)
      when "command_execution"
        [ ClaudeTranscript::Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: {
            name: "command_execution",
            input: { command: item["command"] }.compact,
            id: item["call_id"] || item["id"]
          }
        ) ]
      when "file_change"
        [ ClaudeTranscript::Event.new(
          kind: :system_event,
          timestamp: timestamp,
          data: { type: "file_change", path: item["path"], status: status }.compact
        ) ]
      else
        [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
      end
    end

    def codex_mcp_tool_events(item, timestamp, status)
      id = item["call_id"] || item["id"]
      name = codex_mcp_tool_name(item)
      if item["error"].present? || item["result"].present? || status == "completed"
        content = item["error"].presence || item["result"].presence || { status: status }
        [ ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: id,
            name: name,
            content: content,
            error: item["error"].present?
          }
        ) ]
      else
        [ ClaudeTranscript::Event.new(
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
  end
end
