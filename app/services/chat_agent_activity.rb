class ChatAgentActivity
  TAIL_BYTES = 250.kilobytes
  CODEX_SESSION_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,200}\z/

  Result = Data.define(
    :label,
    :raw_name,
    :in_flight,
    :elapsed_seconds,
    :idle_seconds,
    :transcript_bytes
  ) do
    def as_json(*)
      {
        label: label,
        raw_name: raw_name,
        in_flight: in_flight,
        elapsed_seconds: elapsed_seconds,
        idle_seconds: idle_seconds,
        transcript_bytes: transcript_bytes
      }
    end
  end

  ToolEvent = Data.define(:id, :name, :started_at)

  def self.for(chat_session, now: Time.current)
    new(chat_session, now: now).call
  end

  def self.extract(provider:, jsonl:, now: Time.current, stat: nil)
    adapter_for(provider).new(now: now).extract(jsonl, stat: stat)
  end

  def self.adapter_for(provider)
    {
      "claude" => Adapters::Claude,
      "codex" => Adapters::Codex,
      "muse" => Adapters::Muse
    }.fetch(provider.to_s, Adapters::Unknown)
  end

  def initialize(chat_session, now:)
    @chat_session = chat_session
    @now = now
  end

  def call
    return unless chat_session.turn_in_flight? || chat_session.agent_busy?

    path = transcript_path
    return if path.blank?

    stat = File.stat(path)
    tail = bounded_tail(path, stat.size)
    self.class.extract(provider: provider, jsonl: tail, now: now, stat: stat)
  rescue SystemCallError, JSON::ParserError, TypeError, ArgumentError, ChatProviders::ConfigurationError
    nil
  end

  private

  attr_reader :chat_session, :now

  def provider
    chat_session.effective_chat_provider
  end

  def transcript_path
    self.class.adapter_for(provider).transcript_path_for(chat_session)
  end

  def bounded_tail(path, size)
    File.open(path, "rb") do |file|
      file.seek([ size - TAIL_BYTES, 0 ].max, IO::SEEK_SET)
      file.read(TAIL_BYTES)
    end
  end

  module Adapters
    class Base
      LABELS = {
        "exec_command" => "running commands",
        "bash" => "running commands",
        "command_execution" => "running commands",
        "agent" => "delegating work",
        "task" => "delegating work",
        "subagent.control.spawn_accepted" => "delegating work",
        "propose_job" => "proposing jobs",
        "search_jobs" => "searching code",
        "grep" => "searching code",
        "read" => "searching code",
        "subagent.control.result_ready" => "gathering results",
        "send_chat_message" => "reporting back"
      }.freeze

      def self.transcript_path_for(_chat_session)
        nil
      end

      def initialize(now:)
        @now = now
      end

      def extract(jsonl, stat:)
        events = parsed_events(jsonl)
        return if events.empty?

        in_flight = in_flight_event(events)
        return unless in_flight

        Result.new(
          label: label_for(in_flight.name),
          raw_name: in_flight.name,
          in_flight: true,
          elapsed_seconds: elapsed_seconds(in_flight.started_at),
          idle_seconds: idle_seconds(stat),
          transcript_bytes: stat&.size&.to_i
        )
      rescue StandardError
        nil
      end

      private

      attr_reader :now

      def parsed_events(jsonl)
        jsonl.to_s.each_line.filter_map do |line|
          parsed = JSON.parse(line)
          next unless parsed.is_a?(Hash)

          events_for(parsed)
        rescue JSON::ParserError
          nil
        end.flatten
      end

      def events_for(_parsed)
        []
      end

      def call_event(id:, name:, timestamp:)
        ToolEvent.new(id: id.to_s.presence || name.to_s, name: name.to_s.presence, started_at: parse_time(timestamp))
      end

      def result_event(id:, name: nil, timestamp: nil)
        { id: id.to_s.presence || name.to_s, name: name.to_s.presence, result: true, timestamp: parse_time(timestamp) }
      end

      def in_flight_event(events)
        open = {}

        events.each do |event|
          if event.is_a?(ToolEvent)
            open[event.id] = event if event.name.present?
          elsif event[:result]
            open.delete(event[:id])
          end
        end

        open.values.last
      end

      def label_for(name)
        LABELS.fetch(normalized_name(name), "working")
      end

      def normalized_name(name)
        raw = name.to_s
        raw = raw.split("__").last if raw.start_with?("mcp__")
        raw.downcase
      end

      def parse_time(value)
        return value if value.respond_to?(:to_time)
        return if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def elapsed_seconds(started_at)
        return nil unless started_at

        [ (now.to_time - started_at.to_time).floor, 0 ].max
      end

      def idle_seconds(stat)
        return nil unless stat&.mtime

        [ (now.to_time - stat.mtime.to_time).floor, 0 ].max
      end
    end

    class Unknown < Base
    end

    class Claude < Base
      def self.transcript_path_for(chat_session)
        cwd = ChatWorkspace.path_for(chat_session).to_s
        session_id = chat_session.provider_session_metadata&.session_id
        if session_id.present?
          path = ProviderSession.canonical_path_for(home: ENV.fetch("HOME"), cwd: cwd, session_id: session_id)
          return path if File.exist?(path)
        end

        project_dir = File.dirname(ProviderSession.canonical_path_for(home: ENV.fetch("HOME"), cwd: cwd, session_id: "placeholder"))
        Dir.glob(File.join(project_dir, "*.jsonl")).max_by { |path| File.mtime(path) }
      end

      private

      def events_for(parsed)
        Array(parsed.dig("message", "content")).filter_map do |part|
          next unless part.is_a?(Hash)

          if part["type"] == "tool_use"
            call_event(id: part["id"], name: part["name"], timestamp: parsed["timestamp"])
          elsif part["type"] == "tool_result"
            result_event(id: part["tool_use_id"] || part["id"], timestamp: parsed["timestamp"])
          end
        end
      end
    end

    class Codex < Base
      def self.transcript_path_for(chat_session)
        home = ChatWorkspace.agent_home_for(chat_session, "codex").to_s
        session_id = chat_session.provider_session_metadata&.session_id
        if session_id.present? && session_id.match?(CODEX_SESSION_ID_PATTERN)
          path = Dir.glob(File.join(home, "sessions", "**", "rollout-*-#{session_id}.jsonl")).max_by { |candidate| File.mtime(candidate) }
          return path if path.present?
        end

        Dir.glob(File.join(home, "sessions", "**", "*.jsonl")).max_by { |path| File.mtime(path) }
      end

      private

      def events_for(parsed)
        return response_item_events(parsed) if parsed["type"] == "response_item"
        return item_events(parsed) if parsed["type"].to_s.start_with?("item.")

        []
      end

      def response_item_events(parsed)
        payload = parsed["payload"].is_a?(Hash) ? parsed["payload"] : {}

        if payload["type"] == "function_call"
          call_event(id: payload["call_id"], name: response_item_name(payload), timestamp: parsed["timestamp"])
        elsif payload["type"] == "function_call_output"
          result_event(id: payload["call_id"], name: response_item_name(payload), timestamp: parsed["timestamp"])
        end
      end

      def item_events(parsed)
        item = parsed["item"].is_a?(Hash) ? parsed["item"] : {}
        id = item["call_id"] || item["id"]
        name = item["tool"] || item["name"] || item["type"]

        if parsed["type"] == "item.started"
          call_event(id: id, name: codex_item_name(item, name), timestamp: parsed["timestamp"])
        elsif parsed["type"] == "item.completed" && (item.key?("result") || item.key?("output"))
          result_event(id: id, name: codex_item_name(item, name), timestamp: parsed["timestamp"])
        end
      end

      def response_item_name(payload)
        [ payload["namespace"], payload["name"] ].compact_blank.join("__").presence || payload["type"]
      end

      def codex_item_name(item, fallback)
        if item["server"].present? && item["tool"].present?
          "mcp__#{item["server"]}__#{item["tool"]}"
        else
          fallback
        end
      end
    end

    class Muse < Base
      def self.transcript_path_for(chat_session)
        home = ChatWorkspace.agent_home_for(chat_session, "muse").to_s
        Dir.glob(File.join(home, "**", "*.jsonl")).max_by { |path| File.mtime(path) }
      end

      private

      def events_for(parsed)
        payload_type = parsed["payload_type"].presence || parsed["type"].presence
        payload = parsed["payload"].is_a?(Hash) ? parsed["payload"] : {}

        if payload_type == "subagent.control.spawn_accepted"
          call_event(
            id: muse_subagent_id(payload, fallback: payload_type),
            name: payload_type,
            timestamp: parsed["timestamp"]
          )
        elsif payload_type == "subagent.control.result_ready"
          result_event(
            id: muse_subagent_id(payload, fallback: "subagent.control.spawn_accepted"),
            name: payload_type,
            timestamp: parsed["timestamp"]
          )
        elsif payload_type == "assistant_tool_calls_committed"
          tool_records(payload).map do |record|
            call_event(id: record["call_id"], name: record["tool_name"], timestamp: parsed["timestamp"])
          end
        elsif payload_type == "tool_result_batch_committed"
          tool_records(payload).map do |record|
            result_event(id: record["call_id"], name: record["tool_name"], timestamp: parsed["timestamp"])
          end
        elsif payload_type.to_s.start_with?("tool_batch.effect.")
          tool_batch_events(payload_type, payload, parsed["timestamp"])
        else
          []
        end
      end

      def tool_batch_events(payload_type, payload, timestamp)
        tool_records(payload).filter_map do |record|
          id = record["call_id"] || record["tool_call_id"] || record["id"]
          name = record["tool_name"] || record["name"] || payload_type

          if payload_type.end_with?(".started")
            call_event(id: id, name: name, timestamp: timestamp)
          elsif payload_type.end_with?(".terminal") || payload_type.end_with?(".committed")
            result_event(id: id, name: name, timestamp: timestamp)
          end
        end
      end

      def tool_records(payload)
        records = payload["records"] || payload.dig("tool_batch", "effects") || payload["effects"]
        records = [ payload["record"] ] if records.blank? && payload["record"].is_a?(Hash)
        Array(records).select { |record| record.is_a?(Hash) }
      end

      def muse_subagent_id(payload, fallback:)
        payload["call_id"] || payload["subagent_id"] || payload["id"] || fallback
      end
    end
  end
end
