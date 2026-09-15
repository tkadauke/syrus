module MuseAgent
  module TranscriptEvents
    def muse_event_events(parsed)
      payload_type = parsed["payload_type"].presence || parsed["type"].presence
      payload = parsed["payload"].is_a?(Hash) ? parsed["payload"] : {}
      timestamp = parsed["timestamp"] || payload["timestamp"]

      case payload_type
      when "session.created", "run.session.created", "run.started"
        [ ClaudeTranscript::Event.new(
          kind: :system_init,
          timestamp: timestamp,
          data: {
            model: payload["model"],
            cwd: payload["cwd"] || payload["workspace"],
            tools: Array(payload["tools"] || payload["available_tools"]).map(&:to_s),
            session_id: payload["session_id"].presence || payload["session"].presence
          }.compact
        ) ]
      when "mcp.init", "mcp.tools", "tools.available", "tool.inventory"
        [ ClaudeTranscript::Event.new(
          kind: :system_init,
          timestamp: timestamp,
          data: {
            model: payload["model"],
            cwd: payload["cwd"] || payload["workspace"],
            tools: Array(payload["tools"] || payload["available_tools"]).map(&:to_s),
            session_id: payload["session_id"].presence || payload["session"].presence
          }.compact
        ) ]
      when "assistant.message", "assistant.text", "message.assistant"
        text = payload["final_text"].presence || payload["result"].presence || payload["text"].presence || payload["message"].presence || payload["output"].presence
        text.present? ? [ ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) ] : []
      when "tool.call", "tool_call", "mcp.tool_call"
        [ ClaudeTranscript::Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: {
            name: muse_tool_name(payload),
            input: payload["input"] || payload["arguments"] || {},
            id: payload["id"] || payload["tool_use_id"] || payload["call_id"]
          }.compact
        ) ]
      when "tool.result", "tool_result", "mcp.tool_result"
        [ ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: payload["id"] || payload["tool_use_id"] || payload["call_id"],
            name: muse_tool_name(payload),
            content: payload["content"] || payload["result"],
            error: payload["error"].present? || payload["is_error"] == true
          }.compact
        ) ]
      when "run.terminal.completed"
        [ ClaudeTranscript::Event.new(
          kind: :result,
          timestamp: timestamp,
          data: {
            turns: payload["turns"] || payload["num_turns"],
            cost_usd: payload["cost_usd"] || payload["total_cost_usd"],
            is_error: false,
            subtype: payload["outcome"].presence || payload["status"].presence || "success",
            final_text: payload["final_text"].presence || payload["result"].presence || payload["text"].presence || payload["message"].presence || payload["output"].presence
          }.compact
        ) ]
      when "run.terminal.failed", "run.terminal.error"
        [ ClaudeTranscript::Event.new(
          kind: :result,
          timestamp: timestamp,
          data: {
            turns: payload["turns"] || payload["num_turns"],
            is_error: true,
            subtype: "failed",
            final_text: payload["error"].presence || payload["message"].presence || payload["detail"].presence || "Muse run failed"
          }.compact
        ) ]
      else
        [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
      end
    end

    def muse_tool_name(payload)
      name = payload["name"].presence || payload["tool"].presence || payload["tool_name"].presence
      server = payload["server"].presence || payload["server_name"].presence
      return name if server.blank? || name.to_s.start_with?("mcp__") || name.to_s.include?(".")

      "#{server}.#{name}"
    end
  end
end
