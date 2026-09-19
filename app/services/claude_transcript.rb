require "json"
require "set"

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
  if (events = "ClaudeAgent::TranscriptEvents".safe_constantize)
    include events
  end
  if (events = "CodexAgent::TranscriptEvents".safe_constantize)
    include events
  end
  if (events = "MuseAgent::TranscriptEvents".safe_constantize)
    include events
  end
  if (events = "AgyAgent::TranscriptEvents".safe_constantize)
    include events
  end

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

    parsed_records.each do |record|
      parse_record(record).each { |ev| yield ev }
    end
  end

  def summary
    @summary ||= compute_summary
  end

  private

  def parsed_records
    @parsed_records ||= begin
      records = parse_exported_records
      records.presence || parse_jsonl_records
    end
  end

  def parse_exported_records
    text = @jsonl.strip
    return [] if text.blank?
    return [] unless text.start_with?("{", "[")

    extract_transcript_records(JSON.parse(text))
  rescue JSON::ParserError, TypeError
    []
  end

  def parse_jsonl_records
    @jsonl.each_line.filter_map do |line|
      line = line.strip
      next if line.empty?

      JSON.parse(line)
    rescue JSON::ParserError, TypeError
      nil
    end
  end

  def extract_transcript_records(value)
    case value
    when Array
      value.flat_map { |item| extract_transcript_records(item) }
    when Hash
      child_records = extract_child_record_json(value)
      return child_records if child_records.present?

      events = value["events"]
      return extract_transcript_records(events) if events.is_a?(Array)

      transcript_record?(value) ? [ value ] : []
    else
      []
    end
  end

  def extract_child_record_json(value)
    children = value.dig("envelope", "children")
    return [] unless children.is_a?(Array)

    children.filter_map do |child|
      next unless child.is_a?(Hash)
      raw = child["record_json"].to_s
      next if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end
  end

  def transcript_record?(value)
    value["record_type"].present? ||
      value["payload_type"].present? ||
      value["type"].present? ||
      value["event"].present?
  end

  def parse_record(parsed)
    return [] unless parsed.is_a?(Hash)

    return agy_events(parsed) if parsed["event"].present? && respond_to?(:agy_events, true)

    case parsed["type"].presence || parsed["record_type"].presence
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
    when "event"       then muse_event_events(parsed)
    else                    [ Event.new(kind: :other, timestamp: parsed["timestamp"], data: parsed) ]
    end
  rescue NoMethodError, TypeError
    []
  end

  def compute_summary
    init = nil
    tool_calls = []
    tool_call_ids = Set.new
    result_only_tool_calls = []
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
        tool_call_ids << ev.data[:id].to_s if ev.data[:id].present?
      when :tool_result
        result_tool_name = ev.data[:name].presence
        result_tool_use_id = ev.data[:tool_use_id].to_s
        next if result_tool_name.blank?

        result_only_tool_calls << [ result_tool_use_id.presence, result_tool_name ]
      when :result
        turns = ev.data[:turns]
        cost_usd = ev.data[:cost_usd]
        exit_reason = ev.data[:subtype]
        session_id ||= ev.data[:session_id]
        model      ||= ev.data[:model]
        cwd        ||= ev.data[:cwd]
      end
    end
    result_only_tool_calls.each do |tool_use_id, tool_name|
      next if tool_use_id.present? && tool_call_ids.include?(tool_use_id)

      tool_calls << tool_name
    end

    Summary.new(
      total_turns: turns,
      total_tool_calls: tool_calls.size,
      total_cost_usd: cost_usd,
      exit_reason: exit_reason,
      tool_call_counts: tool_calls.tally,
      mcp_tool_called: tool_calls.any? { |n| n.to_s.start_with?("mcp__") || n.to_s.include?(".") },
      available_tools_at_init: init&.dig(:tools) || [],
      session_id: session_id,
      model: model,
      cwd: cwd
    )
  end
end
