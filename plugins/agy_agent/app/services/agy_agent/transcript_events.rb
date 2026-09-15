module AgyAgent
  module TranscriptEvents
    def agy_events(parsed)
      timestamp = parsed["timestamp"]

      case parsed["event"]
      when "init"
        [ agy_init_event(parsed, timestamp) ]
      when "user"
        [ agy_user_event(parsed, timestamp) ].compact
      when "step_update"
        agy_step_update_events(parsed, timestamp)
      when "result"
        [ agy_result_event(parsed, timestamp) ]
      when "error"
        [ agy_error_event(parsed, timestamp) ]
      else
        [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
      end
    end

    def agy_init_event(parsed, timestamp)
      ClaudeTranscript::Event.new(
        kind: :system_init,
        timestamp: timestamp,
        data: {
          model: parsed["model"],
          cwd: parsed["cwd"],
          tools: Array(parsed["tools"]),
          session_id: parsed["conversation_id"]
        }
      )
    end

    def agy_user_event(parsed, timestamp)
      text = parsed.dig("message", "content").presence || parsed["content"].presence || parsed["text"].presence
      return if text.blank?

      ClaudeTranscript::Event.new(kind: :user_prompt, timestamp: timestamp, data: { text: text })
    end

    def agy_step_update_events(parsed, timestamp)
      events = []
      text = parsed.dig("message", "content").presence || parsed["content"].presence || parsed["text"].presence
      events << ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) if text.present?

      tool_call = parsed["tool_call"] || parsed["toolUse"] || parsed["tool_use"]
      if tool_call.is_a?(Hash)
        events << ClaudeTranscript::Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: {
            name: agy_tool_name(tool_call["name"] || tool_call["tool"]),
            input: tool_call["input"] || tool_call["arguments"] || {},
            id: tool_call["id"] || tool_call["call_id"]
          }
        )
      end

      tool_result = parsed["tool_result"] || parsed["toolResult"]
      if tool_result.is_a?(Hash)
        events << ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: tool_result["id"] || tool_result["call_id"] || tool_result["tool_use_id"],
            name: agy_tool_name(tool_result["name"] || tool_result["tool"]),
            content: tool_result["content"] || tool_result["result"] || tool_result["output"],
            error: tool_result["is_error"] == true || tool_result["error"] == true
          }.compact
        )
      end

      events.presence || [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
    end

    def agy_result_event(parsed, timestamp)
      usage = parsed["usage"] || {}
      ClaudeTranscript::Event.new(
        kind: :result,
        timestamp: timestamp,
        data: {
          turns: parsed["num_turns"] || parsed["turns"],
          duration_ms: parsed["duration_ms"],
          cost_usd: parsed["total_cost_usd"] || parsed["cost_usd"],
          is_error: parsed["is_error"] == true,
          subtype: parsed["subtype"].presence || (parsed["is_error"] == true ? "error" : "success"),
          final_text: parsed["result"] || parsed["text"] || parsed.dig("message", "content"),
          usage: usage.presence
        }.compact
      )
    end

    def agy_error_event(parsed, timestamp)
      ClaudeTranscript::Event.new(
        kind: :result,
        timestamp: timestamp,
        data: {
          turns: parsed["num_turns"] || parsed["turns"],
          is_error: true,
          subtype: "error",
          final_text: parsed["message"] || parsed["error"] || "Antigravity run failed"
        }
      )
    end

    def agy_tool_name(name)
      raw = name.to_s
      if (match = raw.match(/\Amcp\((.+?)\/(.+?)\)\z/))
        "mcp__#{match[1]}__#{match[2]}"
      else
        raw.presence
      end
    end
  end
end
