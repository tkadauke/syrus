module Observability
  module EventStream
    class Persistence
      def self.for(mode)
        {
          create_each: CreateEach,
          insert_all: InsertAll
        }.fetch(mode.to_sym).new
      end

      def persist(_model, _rows)
        raise NotImplementedError
      end

      class CreateEach < self
        def persist(model, rows)
          rows.each { |row| model.create!(row) }
        end
      end

      class InsertAll < self
        def persist(model, rows)
          model.insert_all(normalize_rows(rows)) # rubocop:disable Rails/SkipsModelValidations
        end

        private

        def normalize_rows(rows)
          keys = rows.flat_map(&:keys).uniq
          rows.map { |row| keys.index_with { |key| row[key] } }
        end
      end
    end

    Stream = Struct.new(:kind, :model_name, :durable, :persistence, :batch_size, keyword_init: true) do
      def model
        model_name.to_s.constantize
      end

      def durable?
        !!durable
      end

      def persist!(events, batch_size:)
        rows = events.filter_map { |event| model.from_event_hash(event) }
        return if rows.empty?

        effective_batch_size = self.batch_size || batch_size
        if model.respond_to?(:persist_observability_events!)
          model.persist_observability_events!(rows, batch_size: effective_batch_size)
          return
        end

        rows.each_slice(effective_batch_size) do |batch|
          persistence.persist(model, batch)
        end
      end

      def recent(limit:)
        return [] unless model.respond_to?(:as_recent_event_hashes)

        model.as_recent_event_hashes(limit: limit)
      end
    end

    @streams = {}

    module_function

    def register(kind, model:, durable: false, persist: :insert_all, batch_size: nil)
      kind = normalize_kind(kind)
      @streams[kind] = Stream.new(
        kind: kind,
        model_name: model.to_s,
        durable: durable,
        persistence: Persistence.for(persist),
        batch_size: normalized_batch_size(batch_size)
      )
    end

    def fetch(kind)
      streams.fetch(normalize_kind(kind)) { raise ArgumentError, "unknown observability event kind: #{kind}" }
    end

    def kinds
      streams.keys
    end

    def durable_kinds
      streams.values.select(&:durable?).map(&:kind)
    end

    def streams
      register_defaults if @streams.empty?
      @streams
    end

    def normalize_kind(kind)
      kind.to_sym
    end

    def normalized_batch_size(value)
      value = Integer(value, exception: false)
      return unless value&.positive?

      value
    end

    def register_defaults
      register(
        :performance,
        model: "PerformanceLogEvent",
        batch_size: Integer(ENV["SYRUS_PERFORMANCE_FLUSH_BATCH_SIZE"], exception: false) || 25
      )
      register(:operational, model: "OperationalLogEvent", durable: true, persist: :create_each)
      register(:work_engine_reconciler_activity, model: "WorkEngineReconcilerActivityEvent")
      register(:workflow_activity, model: "WorkflowActivityEvent", durable: true)
      register(:mcp_startup_phase, model: "McpStartupPhaseEvent", durable: true)
    end
  end
end
