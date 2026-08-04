module RunResourceSummaries
  class Builder
    def initialize(run:, now: Time.current)
      @run = run
      @now = now
    end

    def refresh!
      summary = RunResourceSummary.find_or_initialize_by(run: run)
      summary.assign_attributes(attributes)
      summary.save!
      summary
    end

    private

    attr_reader :run, :now

    def attributes
      {
        job: run.job,
        workflow: workflow,
        step: step,
        repository_id: run.job&.repository_id,
        user: run.user,
        agent_provider: run.agent_provider,
        trigger_kind: workflow&.trigger_kind || run.trigger_kind,
        step_kind: step&.kind,
        grader_name: grader_name,
        hostname: correlation[:primary_hostname],
        started_at: range_start,
        finished_at: range_finish,
        duration_seconds: duration_seconds,
        host_sample_count: host_sample_count,
        host_sample_confidence: host_sample_confidence,
        host_usage_avg_cpu_used_percent: host_metric(:cpu_used_percent, :avg),
        host_usage_max_cpu_used_percent: host_metric(:cpu_used_percent, :max),
        host_pressure_avg_cpu_some_percent: host_metric(:cpu_pressure_some, :avg),
        host_pressure_max_cpu_some_percent: host_metric(:cpu_pressure_some, :max),
        host_usage_avg_memory_used_percent: host_metric(:memory_used_percent, :avg),
        host_usage_max_memory_used_percent: host_metric(:memory_used_percent, :max),
        host_pressure_avg_io_some_percent: host_metric(:io_pressure_some, :avg),
        host_pressure_max_io_some_percent: host_metric(:io_pressure_some, :max),
        host_usage_max_data_root_used_percent: host_metric(:data_root_used_percent, :max),
        spawned_process_count: processes.size,
        command_span_count: command_spans.size,
        host_pressure_level: correlation.fetch(:pressure).fetch(:level),
        host_pressure_reasons: correlation.fetch(:pressure).fetch(:reasons),
        process_attribution_method: process_summary.fetch(:method),
        process_attribution_version: ProcessAttribution::VERSION,
        process_attribution_confidence: process_summary.fetch(:confidence),
        process_sample_count: process_summary.fetch(:sample_count),
        process_cpu_time_seconds: process_summary.fetch(:cpu_time_seconds),
        process_wall_time_seconds: process_summary.fetch(:wall_time_seconds),
        process_max_rss_bytes: process_summary.fetch(:max_rss_bytes),
        process_read_io_bytes: process_summary.fetch(:read_io_bytes),
        process_write_io_bytes: process_summary.fetch(:write_io_bytes),
        process_descendant_process_count: process_summary.fetch(:descendant_process_count),
        process_exit_statuses: process_summary.fetch(:exit_statuses),
        process_attribution_unavailable_reason: process_summary.fetch(:unavailable_reason),
        process_resource_fallback: process_summary.fetch(:fallback),
        process_attributed_sample_count: process_summary.fetch(:sample_count).to_i.positive? ? 1 : 0,
        process_attributed_duration_seconds: process_summary.fetch(:wall_time_seconds),
        process_attributed_cpu_seconds: process_summary.fetch(:cpu_time_seconds),
        process_attributed_cpu_percent: process_cpu_percent,
        process_attributed_memory_bytes: process_summary.fetch(:max_rss_bytes),
        process_attributed_io_bytes: process_io_bytes,
        retention_limited: correlation.fetch(:retention_limited),
        summary_version: RunResourceSummary::SUMMARY_VERSION
      }
    end

    def process_cpu_percent
      cpu_seconds = process_summary.fetch(:cpu_time_seconds)
      wall_seconds = process_summary.fetch(:wall_time_seconds)
      return unless cpu_seconds && wall_seconds.to_f.positive?

      ((cpu_seconds.to_f / wall_seconds.to_f) * 100.0).round(3)
    end

    def process_io_bytes
      read_bytes = process_summary.fetch(:read_io_bytes).to_i
      write_bytes = process_summary.fetch(:write_io_bytes).to_i
      total = read_bytes + write_bytes
      total.positive? ? total : nil
    end

    def host_metric(name, part)
      correlation.fetch(:summary).dig(name, part)
    end

    def host_sample_confidence
      return "unknown" if host_sample_count.zero?
      return "low" if duration_seconds && duration_seconds < 60 && host_sample_count < 3

      host_sample_count >= required_sample_count ? "sufficient" : "insufficient"
    end

    def required_sample_count
      return 1 if duration_seconds.nil? || duration_seconds < 60
      return 3 if duration_seconds < 10.minutes.to_i

      10
    end

    def host_sample_count
      correlation.fetch(:sample_count)
    end

    def range_start
      @range_start ||= run.started_at || run.created_at
    end

    def range_finish
      @range_finish ||= run.finished_at || now
    end

    def duration_seconds
      return unless range_start && range_finish

      (range_finish - range_start).to_f.round(3)
    end

    def workflow
      @workflow ||= run.workflow
    end

    def step
      @step ||= run.step
    end

    def correlation
      @correlation ||= WorkerHealthRunCorrelation.for_run(run, sample_limit: 0, now: now)
    end

    def processes
      @processes ||= run.spawned_processes.order(:started_at, :id).to_a
    end

    def command_spans
      @command_spans ||= run.command_spans.ordered.to_a
    end

    def process_summary
      @process_summary ||= ProcessAttribution.new(processes: processes, command_spans: command_spans, now: now).summary
    end

    def grader_name
      return unless step&.kind == "grader"

      step.details["name"].presence
    end

    class ProcessAttribution
      VERSION = 1

      def initialize(processes:, command_spans:, now:)
        @processes = processes
        @command_spans = command_spans
        @now = now
      end

      def summary
        measured = measurements.select(&:measured?)

        {
          method: method_for(measured),
          confidence: confidence_for(measured),
          sample_count: measurements.sum(&:sample_count),
          cpu_time_seconds: sum_metric(measured, :cpu_time_seconds),
          wall_time_seconds: wall_time_seconds,
          max_rss_bytes: max_metric(measured, :max_rss_bytes),
          read_io_bytes: sum_metric(measured, :read_io_bytes),
          write_io_bytes: sum_metric(measured, :write_io_bytes),
          descendant_process_count: sum_metric(measured, :descendant_process_count) || 0,
          exit_statuses: exit_statuses,
          unavailable_reason: unavailable_reason(measured),
          fallback: measured.empty?
        }
      end

      private

      attr_reader :processes, :command_spans, :now

      def measurements
        @measurements ||= measurement_owners.filter_map { |owner| Measurement.from(owner) }
      end

      def measurement_owners
        process_ids = processes.map(&:id).compact
        processes + command_spans.reject { |span| process_ids.include?(span.spawned_process_id) }
      end

      def method_for(measured)
        return "none" if processes.empty? && command_spans.empty?
        return "unavailable_host_fallback" if measured.empty?

        measured.map(&:method).compact_blank.uniq.sort.join("+").presence || "process_owner"
      end

      def confidence_for(measured)
        return "unknown" if processes.empty? && command_spans.empty?
        return "low" if measured.empty?

        ordered_confidences = %w[ unknown low medium high ]
        measured.map(&:confidence).min_by { |confidence| ordered_confidences.index(confidence) || 0 } || "low"
      end

      def wall_time_seconds
        owners = processes.presence || command_spans
        return nil if owners.empty?

        owners.sum do |owner|
          started_at = owner.started_at
          finished_at = owner.finished_at || now
          started_at && finished_at ? (finished_at - started_at).to_f : 0.0
        end.round(3)
      end

      def exit_statuses
        (processes.map { |process| exit_status_payload("spawned_process", process) } +
          command_spans.map { |span| exit_status_payload("command_span", span) }).first(50)
      end

      def exit_status_payload(owner_type, owner)
        {
          owner_type: owner_type,
          id: owner.id,
          exit_status: owner.exit_status,
          outcome: owner.outcome
        }
      end

      def unavailable_reason(measured)
        return "no spawned process or command span records" if processes.empty? && command_spans.empty?
        return nil if measured.any?

        "process resource accounting unavailable; host metrics retained separately"
      end

      def sum_metric(measured, name)
        values = measured.filter_map { |measurement| measurement.public_send(name) }
        values.presence&.sum
      end

      def max_metric(measured, name)
        measured.filter_map { |measurement| measurement.public_send(name) }.max
      end

      Measurement = Data.define(
        :method, :confidence, :sample_count, :cpu_time_seconds, :max_rss_bytes,
        :read_io_bytes, :write_io_bytes, :descendant_process_count
      ) do
        NUMERIC_KEYS = %w[
          sample_count
          cpu_time_seconds
          max_rss_bytes
          read_io_bytes
          write_io_bytes
          descendant_process_count
        ].freeze

        def self.from(owner)
          payload = (owner.resource_attribution || {}).stringify_keys
          values = payload.stringify_keys.slice(*NUMERIC_KEYS)
          return nil if values.empty? && payload.blank?

          new(
            method: payload["method"].presence || payload["attribution_method"].presence,
            confidence: payload["confidence"].presence || "unknown",
            sample_count: integer_value(payload["sample_count"]) || 0,
            cpu_time_seconds: float_value(payload["cpu_time_seconds"]),
            max_rss_bytes: integer_value(payload["max_rss_bytes"]),
            read_io_bytes: integer_value(payload["read_io_bytes"]),
            write_io_bytes: integer_value(payload["write_io_bytes"]),
            descendant_process_count: integer_value(payload["descendant_process_count"])
          )
        end

        def measured?
          sample_count.positive? ||
            cpu_time_seconds.present? ||
            max_rss_bytes.present? ||
            read_io_bytes.present? ||
            write_io_bytes.present? ||
            descendant_process_count.present?
        end

        def self.integer_value(value)
          Integer(value) if value.present?
        rescue ArgumentError, TypeError
          nil
        end

        def self.float_value(value)
          Float(value) if value.present?
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
