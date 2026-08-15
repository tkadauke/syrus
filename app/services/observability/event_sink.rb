require "fileutils"
require "securerandom"

module Observability
  module EventSink
    KINDS = %i[ performance operational ].freeze
    MEMORY_LIMIT = Integer(ENV["SYRUS_OBSERVABILITY_MEMORY_EVENTS"], exception: false) || 500
    FLUSH_BATCH_SIZE = Integer(ENV["SYRUS_OBSERVABILITY_FLUSH_BATCH_SIZE"], exception: false) || 250
    FLUSH_INTERVAL = (Integer(ENV["SYRUS_OBSERVABILITY_FLUSH_INTERVAL_SECONDS"], exception: false) || 15).seconds
    SPOOL_KINDS = %i[ operational ].freeze

    @mutex = Mutex.new
    @buffers = Hash.new { |hash, key| hash[key] = [] }
    @dropped = Hash.new(0)
    @flusher_thread = nil

    module_function

    def append(kind:, event:, durable: false)
      kind = normalize_kind(kind)
      event = normalized_event(event)
      append_memory(kind, event)
      append_spool(kind, event) if durable || SPOOL_KINDS.include?(kind)
      start_background_flusher
      event
    rescue StandardError => e
      Rails.logger.error("[Observability::EventSink] append failed for #{kind} event, event dropped: #{e.class}: #{e.message}")
      nil
    end

    def recent(kind:, limit:)
      kind = normalize_kind(kind)
      limit = clamp_limit(limit)
      persisted = persisted_recent(kind, limit: limit)
      buffered = buffered_events(kind)
      (persisted + buffered)
        .uniq { |event| event_identity(event) }
        .sort_by { |event| event["occurred_at"].to_s }
        .last(limit)
        .reverse
    rescue StandardError
      buffered_events(kind).last(limit).reverse
    end

    def flush!(kinds: KINDS)
      Array(kinds).each { |kind| flush_kind!(normalize_kind(kind)) }
    end

    def clear!(kind: nil)
      @mutex.synchronize do
        if kind
          kind = normalize_kind(kind)
          @buffers[kind] = []
          clear_spool(kind)
        else
          @buffers.clear
          KINDS.each { |event_kind| clear_spool(event_kind) }
        end
      end
    end

    def stats
      @mutex.synchronize do
        {
          buffered: @buffers.transform_values(&:size),
          dropped: @dropped.dup,
          spool_root: spool_root.to_s,
          background_flusher: @flusher_thread&.alive? || false
        }
      end
    end

    def clamp_limit(limit)
      [[limit.to_i, 1].max, MEMORY_LIMIT].min
    end

    def flush_kind!(kind)
      events = drain_memory(kind)
      events.concat(drain_spool(kind))
      events = events.uniq { |event| event_identity(event) }
      return if events.empty?

      case kind
      when :performance
        PerformanceLogging.suppress do
          events.each_slice(FLUSH_BATCH_SIZE) do |batch|
            PerformanceLogEvent.insert_all(batch.map { |event| PerformanceLogEvent.from_event_hash(event) }) # rubocop:disable Rails/SkipsModelValidations
          end
        end
      when :operational
        OperationalLogging.suppress do
          events.each_slice(FLUSH_BATCH_SIZE) do |batch|
            batch.each do |event|
              row = operational_row(event)
              OperationalLogEvent.create!(row) if row
            end
          end
        end
      end
    rescue StandardError => e
      Rails.logger.error("[Observability::EventSink] flush failed for #{kind}, #{events.size} event(s) restored to buffer: #{e.class}: #{e.message}")
      restore_memory(kind, events)
      nil
    end

    def start_background_flusher
      return unless background_flusher_enabled?
      return if @mutex.synchronize { @flusher_thread&.alive? }

      @mutex.synchronize do
        return if @flusher_thread&.alive?

        @flusher_thread = Thread.new do
          Thread.current.name = "syrus-observability-flusher" if Thread.current.respond_to?(:name=)
          Thread.current.report_on_exception = false
          loop do
            sleep FLUSH_INTERVAL
            flush!
          rescue StandardError => e
            Rails.logger.error("[Observability::EventSink] background flusher iteration failed: #{e.class}: #{e.message}")
          end
        end
      end
    end

    def background_flusher_enabled?
      configured = ENV["SYRUS_OBSERVABILITY_BACKGROUND_FLUSHER"]
      return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

      !Rails.env.test?
    end

    def persisted_recent(kind, limit:)
      case kind
      when :performance
        PerformanceLogEvent.recent_first.limit(limit).map(&:as_event_hash)
      when :operational
        []
      else
        []
      end
    end

    def append_memory(kind, event)
      @mutex.synchronize do
        buffer = @buffers[kind]
        buffer << event
        overflow = buffer.size - MEMORY_LIMIT
        if overflow.positive?
          @dropped[kind] += overflow
          @buffers[kind] = buffer.last(MEMORY_LIMIT)
        end
      end
    end

    def restore_memory(kind, events)
      return if events.blank?

      @mutex.synchronize { @buffers[kind] = (events + @buffers[kind]).last(MEMORY_LIMIT) }
    end

    def drain_memory(kind)
      @mutex.synchronize do
        events = @buffers[kind]
        @buffers[kind] = []
        events
      end
    end

    def buffered_events(kind)
      @mutex.synchronize { @buffers[kind].dup }
    end

    def append_spool(kind, event)
      FileUtils.mkdir_p(spool_dir(kind))
      File.open(spool_path(kind), "a") { |file| file.puts(JSON.generate(event)) }
    rescue StandardError
      nil
    end

    def clear_spool(kind)
      FileUtils.rm_rf(spool_dir(kind))
    rescue StandardError
      nil
    end

    def drain_spool(kind)
      dir = spool_dir(kind)
      return [] unless dir.exist?

      Dir.children(dir).grep(/\.jsonl\z/).flat_map do |filename|
        path = dir.join(filename)
        claimed = dir.join("#{filename}.#{Process.pid}.claiming")
        File.rename(path, claimed)
        events = File.readlines(claimed, chomp: true).filter_map { |line| JSON.parse(line) rescue nil }
        File.delete(claimed)
        events
      rescue StandardError
        []
      end
    end

    def spool_path(kind)
      spool_dir(kind).join("#{process_identity}.jsonl")
    end

    def spool_dir(kind)
      spool_root.join(kind.to_s, SyrusVersion.hostname.to_s.presence || "unknown-host")
    end

    def spool_root
      Pathname.new(ENV.fetch("SYRUS_OBSERVABILITY_SPOOL_ROOT") {
        Rails.root.join("tmp", "observability_spool").to_s
      })
    end

    def process_identity
      @process_identity ||= [
        ENV["SYRUS_PROCESS_ROLE"].presence || ENV["RAILS_PROCESS_ROLE"].presence || "rails",
        Process.pid,
        SecureRandom.hex(6)
      ].join("-")
    end

    def normalize_kind(kind)
      kind = kind.to_sym
      return kind if KINDS.include?(kind)

      raise ArgumentError, "unknown observability event kind: #{kind}"
    end

    def normalized_event(event)
      event.to_h.deep_stringify_keys
    end

    def event_identity(event)
      [ event["occurred_at"], event["event"], event["request_id"], event["phase"], event["name"], event["message"] ]
    end

    def operational_row(event)
      {
        occurred_at: PerformanceLogEvent.parse_time(event["occurred_at"]) || Time.current,
        level: event["level"],
        role: event["role"],
        hostname: event["hostname"],
        app_revision: event["app_revision"],
        pid: event["pid"],
        source: event["source"],
        request_id: event["request_id"],
        job_id: event["job_id"],
        workflow_id: event["workflow_id"],
        run_id: event["run_id"],
        message: event["message"],
        context: event["context"] || {},
        created_at: Time.current,
        updated_at: Time.current
      }.compact
    end

  end
end
