module MuseAgent
  module TranscriptEvents
    def muse_event_events(parsed)
      payload_type = parsed["payload_type"].presence || parsed["type"].presence
      payload = parsed["payload"].is_a?(Hash) ? parsed["payload"] : {}
      timestamp = parsed["timestamp"] || payload["timestamp"]

      case payload_type
      when "session.created", "run.session.created", "run.started"
        [ muse_system_init_event(payload, timestamp) ]
      when "mcp.init", "mcp.tools", "tools.available", "tool.inventory"
        [ muse_system_init_event(payload, timestamp) ]
      when "turn.input.user", "user.message", "message.user"
        text = muse_payload_text(payload)
        text.present? ? [ ClaudeTranscript::Event.new(kind: :user_prompt, timestamp: timestamp, data: { text: text }) ] : []
      when "run.output.delta", "run.output.text", "assistant.message", "assistant.text", "message.assistant"
        text = muse_payload_text(payload)
        text.present? ? [ ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: text }) ] : []
      when "tool.call", "tool_call", "tool.use", "mcp.tool_call", "mcp.tool.call", "msp.tool_call", "msp.tool.call"
        [ ClaudeTranscript::Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: {
            name: muse_tool_name(payload),
            input: muse_tool_input(payload),
            id: muse_tool_id(payload)
          }.compact
        ) ]
      when "tool.result", "tool_result", "tool.output", "mcp.tool_result", "mcp.tool.result", "msp.tool_result", "msp.tool.result"
        [ ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: muse_tool_id(payload),
            name: muse_tool_name(payload),
            content: muse_tool_result_content(payload),
            error: muse_error?(payload)
          }.compact
        ) ]
      when /\Atask\.lifecycle\./
        [ ClaudeTranscript::Event.new(
          kind: :other,
          timestamp: timestamp,
          data: {
            type: payload_type,
            status: payload["status"],
            message: muse_payload_text(payload).presence || payload["detail"].presence || payload["error"].presence,
            task_id: payload["task_id"] || payload["id"]
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
            final_text: muse_payload_text(payload),
            session_id: payload["session_id"].presence || payload["session"].presence,
            model: payload["model"],
            cwd: payload["cwd"] || payload["workspace"]
          }.compact
        ) ]
      when "run.terminal.failed", "run.terminal.error"
        [ ClaudeTranscript::Event.new(
          kind: :result,
          timestamp: timestamp,
          data: {
            turns: payload["turns"] || payload["num_turns"],
            is_error: true,
            subtype: payload["outcome"].presence || payload["status"].presence || "failed",
            final_text: payload["error"].presence || payload["message"].presence || payload["detail"].presence || muse_payload_text(payload).presence || "Muse run failed",
            session_id: payload["session_id"].presence || payload["session"].presence,
            model: payload["model"],
            cwd: payload["cwd"] || payload["workspace"]
          }.compact
        ) ]
      else
        [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
      end
    end

    def muse_tool_name(payload)
      name = payload["name"].presence || payload["tool"].presence || payload["tool_name"].presence
      server = payload["server"].presence || payload["server_name"].presence
      return nil if name.blank?
      return name if server.blank? || name.to_s.start_with?("mcp__") || name.to_s.include?(".")

      "#{server}.#{name}"
    end

    def muse_system_init_event(payload, timestamp)
      ClaudeTranscript::Event.new(
        kind: :system_init,
        timestamp: timestamp,
        data: {
          model: payload["model"],
          cwd: payload["cwd"] || payload["workspace"],
          tools: muse_tools(payload),
          session_id: payload["session_id"].presence || payload["session"].presence
        }.compact
      )
    end

    def muse_tools(payload)
      raw_tools = payload["tools"] || payload["available_tools"] || payload["tool_names"]
      Array(raw_tools).filter_map do |tool|
        if tool.is_a?(Hash)
          muse_tool_name(tool).presence || tool["id"].presence
        else
          tool.to_s.presence
        end
      end
    end

    def muse_payload_text(payload)
      value = payload["delta"].presence ||
        payload["final_text"].presence ||
        payload["result"].presence ||
        payload["text"].presence ||
        payload["message"].presence ||
        payload["output"].presence ||
        payload["content"].presence

      return value if value.is_a?(String)
      return value.map { |part| muse_content_text(part) }.compact_blank.join("\n") if value.is_a?(Array)

      value.to_json if value.is_a?(Hash)
    end

    def muse_content_text(part)
      return part if part.is_a?(String)
      return unless part.is_a?(Hash)

      part["text"].presence || part["content"].presence || part["delta"].presence
    end

    def muse_tool_input(payload)
      value = payload["input"] || payload["arguments"] || payload["args"]
      return {} if value.blank?
      return JSON.parse(value) if value.is_a?(String) && value.strip.start_with?("{")

      value
    rescue JSON::ParserError
      value
    end

    def muse_tool_id(payload)
      payload["id"] || payload["tool_use_id"] || payload["call_id"] || payload["invocation_id"]
    end

    def muse_tool_result_content(payload)
      payload["content"] || payload["result"] || payload["output"] || payload["data"]
    end

    def muse_error?(payload)
      payload["error"].present? || payload["is_error"] == true || payload["status"].to_s == "error"
    end
  end
end
