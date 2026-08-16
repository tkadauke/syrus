module Observability
  module EventStream
    Stream = Struct.new(:kind, :model_name, :durable, :persist_mode, keyword_init: true) do
      def model
        model_name.to_s.constantize
      end

      def durable?
        !!durable
      end

      def persist!(events, batch_size:)
        rows = events.filter_map { |event| model.from_event_hash(event) }
        return if rows.empty?

        rows.each_slice(batch_size) do |batch|
          case persist_mode
          when :create_each
            batch.each { |row| model.create!(row) }
          else
            model.insert_all(normalize_insert_rows(batch)) # rubocop:disable Rails/SkipsModelValidations
          end
        end
      end

      def recent(limit:)
        return [] unless model.respond_to?(:as_recent_event_hashes)

        model.as_recent_event_hashes(limit: limit)
      end

      private

      def normalize_insert_rows(rows)
        keys = rows.flat_map(&:keys).uniq
        rows.map { |row| keys.index_with { |key| row[key] } }
      end
    end

    @streams = {}

    module_function

    def register(kind, model:, durable: false, persist: :insert_all)
      kind = normalize_kind(kind)
      @streams[kind] = Stream.new(kind: kind, model_name: model.to_s, durable: durable, persist_mode: persist.to_sym)
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

    def register_defaults
      register(:performance, model: "PerformanceLogEvent")
      register(:operational, model: "OperationalLogEvent", durable: true, persist: :create_each)
      register(:work_engine_reconciler_activity, model: "WorkEngineReconcilerActivityEvent")
      register(:workflow_activity, model: "WorkflowActivityEvent", durable: true)
    end
  end
end
