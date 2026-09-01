module ClaudeAgent
  module TranscriptEvents
    # Claude-code wraps a session_id and (optionally) tool list in
    # `system` events with subtype `init`. Older / different shapes
    # may put the same info elsewhere; degrade gracefully.
    def system_event(parsed)
      if parsed["subtype"] == "init"
        ClaudeTranscript::Event.new(
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
        ClaudeTranscript::Event.new(kind: :other, timestamp: parsed["timestamp"], data: parsed)
      end
    end

    # `user` events carry either the operator's prompt (string content)
    # or `tool_result` blocks (array content). String → user_prompt.
    # Array → one tool_result event per block.
    def user_events(parsed)
      content = parsed.dig("message", "content")
      timestamp = parsed["timestamp"]
      meta = sidechain_metadata(parsed)

      if content.is_a?(String)
        [ ClaudeTranscript::Event.new(kind: :user_prompt, timestamp: timestamp, data: { text: content }.merge(meta)) ]
      elsif content.is_a?(Array)
        content.filter_map do |c|
          next unless c["type"] == "tool_result"
          ClaudeTranscript::Event.new(
            kind: :tool_result,
            timestamp: timestamp,
            data: {
              tool_use_id: c["tool_use_id"],
              content: c["content"],
              error: c["is_error"] == true
            }.merge(meta)
          )
        end
      else
        [ ClaudeTranscript::Event.new(kind: :other, timestamp: timestamp, data: parsed) ]
      end
    end

    # `assistant` events have a content array mixing text and
    # tool_use entries. Yield each block as its own event in order.
    def assistant_events(parsed)
      content = parsed.dig("message", "content") || []
      timestamp = parsed["timestamp"]
      meta = sidechain_metadata(parsed)
      content.filter_map do |block|
        case block["type"]
        when "text"
          ClaudeTranscript::Event.new(kind: :assistant_text, timestamp: timestamp, data: { text: block["text"] }.merge(meta))
        when "tool_use"
          ClaudeTranscript::Event.new(
            kind: :tool_use,
            timestamp: timestamp,
            data: { name: block["name"], input: block["input"], id: block["id"] }.merge(meta)
          )
        end
      end
    end

    # Claude-code tags subagent (Task/Agent tool) transcript lines with
    # `isSidechain: true`. The on-disk per-session transcript doesn't carry
    # the spawning tool_use id inline -- subagent turns are written to sibling
    # `subagents/agent-<id>.jsonl` files instead, correlated to the parent
    # tool_use via a `.meta.json` sidecar (see
    # ChatProviders::Claude#session_capture, which merges those files in and
    # stamps `parentToolUseId` onto each line before handing the combined
    # JSONL here). Forward whatever is present on the line so a flat
    # consumer can reconstruct nesting instead of discarding it.
    def sidechain_metadata(parsed)
      {
        sidechain: parsed["isSidechain"] == true,
        parent_tool_use_id: parsed["parentToolUseId"]
      }
    end

    def result_event(parsed)
      ClaudeTranscript::Event.new(
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
  end
end
