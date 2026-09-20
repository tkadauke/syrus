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
      when "task.lifecycle.side_effect_intent"
        muse_side_effect_tool_event(payload, timestamp)
      when "assistant_tool_calls_committed"
        muse_tool_batch_effect_events(payload, timestamp)
      when /\Atool_batch\.effect\./
        muse_tool_batch_effect_events(payload, timestamp)
      when "tool_result_batch_committed"
        muse_tool_batch_result_events(payload, timestamp)
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
      name ||= payload.dig("correlation_facts", "tool_name") if payload["correlation_facts"].is_a?(Hash)
      server = payload["server"].presence || payload["server_name"].presence
      return nil if name.blank?
      return name if server.blank? || name.to_s.start_with?("mcp__") || name.to_s.include?(".")

      "#{server}.#{name}"
    end

    def muse_side_effect_tool_event(payload, timestamp)
      event = payload["event"].is_a?(Hash) ? payload["event"] : {}
      operation = event["operation"].to_s
      return [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: { type: "task.lifecycle.side_effect_intent" }) ] unless operation.start_with?("tool:")

      [ ClaudeTranscript::Event.new(
        kind: :tool_use,
        timestamp: timestamp,
        data: {
          name: operation.delete_prefix("tool:"),
          input: muse_tool_call_arguments(event["input"], event["arguments"], event["args"], payload["input"], payload["arguments"], payload["args"]),
          id: event["idempotency_key"].to_s.delete_prefix("tool:").presence
        }.compact
      ) ]
    end

    def muse_tool_batch_effect_events(payload, timestamp)
      events = muse_tool_batch_effects(payload).filter_map do |effect|
        name = muse_tool_record_name(effect)
        next if name.blank?

        ClaudeTranscript::Event.new(
          kind: :tool_use,
          timestamp: timestamp,
          data: {
            name: name,
            input: muse_tool_record_input(effect, payload) || {},
            id: muse_tool_record_id(effect)
          }.compact
        )
      end
      events.presence || [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: { type: "tool_batch.effect" }) ]
    end

    def muse_tool_batch_result_events(payload, timestamp)
      events = muse_tool_batch_effects(payload).map do |effect|
        ClaudeTranscript::Event.new(
          kind: :tool_result,
          timestamp: timestamp,
          data: {
            tool_use_id: muse_tool_record_id(effect),
            name: muse_tool_record_name(effect),
            content: muse_tool_record_result(effect, payload),
            error: effect["error"].present? || effect["is_error"] == true || effect["status"].to_s == "error"
          }.compact
        )
      end
      events.presence || [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: { type: "tool_result_batch_committed" }) ]
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
      muse_tool_call_arguments(payload["input"], payload["arguments"], payload["args"])
    end

    # See MuseInvocation#tool_call_arguments -- this mirrors that extraction
    # so the transcript-rendering path and the live chat-persistence path
    # (MuseInvocation) never disagree about which key carries a tool call's
    # model-authored arguments.
    def muse_tool_call_arguments(*candidates)
      value = candidates.find(&:present?)
      return {} if value.blank?
      return JSON.parse(value) if value.is_a?(String) && value.strip.start_with?("{")

      value
    rescue JSON::ParserError
      value
    end

    def muse_tool_id(payload)
      payload["id"] || payload["tool_use_id"] || payload["call_id"] || payload["invocation_id"]
    end

    def muse_tool_batch_effects(payload)
      candidates = [
        payload["record"],
        payload["records"],
        payload["effect"],
        payload["event"],
        payload["effects"],
        payload["events"],
        payload["tool_calls"],
        payload["tool_results"],
        payload["tool_effects"],
        payload.dig("tool_batch", "effects")
      ].flatten.compact
      candidates.select { |candidate| candidate.is_a?(Hash) }
    end

    def muse_tool_record_name(record)
      operation = record["operation"].to_s
      return operation.delete_prefix("tool:") if operation.start_with?("tool:")

      record["tool_name"].presence || record["name"].presence || record["tool"].presence
    end

    def muse_tool_record_id(record)
      record["idempotency_key"].to_s.delete_prefix("tool:").presence ||
        record["call_id"].presence ||
        record["tool_use_id"].presence ||
        record["id"].presence ||
        record["invocation_id"].presence
    end

    def muse_tool_record_input(record, payload)
      muse_tool_call_arguments(record["input"], record["arguments"], record["args"], payload["input"], payload["arguments"], payload["args"])
    end

    def muse_tool_record_result(record, payload)
      record["content"] || record["result"] || record["output"] || record["data"] || record["text"] ||
        payload["content"] || payload["result"] || payload["output"] || payload["data"] || payload["text"]
    end

    def muse_tool_result_content(payload)
      payload["content"] || payload["result"] || payload["output"] || payload["data"] || payload["text"]
    end

    def muse_error?(payload)
      payload["error"].present? || payload["is_error"] == true || payload["status"].to_s == "error"
    end
  end
end
