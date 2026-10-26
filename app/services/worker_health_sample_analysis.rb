class WorkerHealthSampleAnalysis
  NUMERIC_FIELDS = %i[
    cpu_used_percent
    memory_used_percent
    data_root_used_percent
    load_1m
    load_5m
    load_15m
    cpu_pressure_some
    cpu_pressure_full
    io_pressure_some
    io_pressure_full
  ].freeze

  LEVEL_ORDER = {
    "unknown" => 0,
    "ok" => 1,
    "warning" => 2,
    "critical" => 3
  }.freeze

  # Each entry carries a stable dimension key alongside the human-readable
  # label: a caller that has to act on *which* resource is saturated (see
  # RunHostAdmission) needs more than the prose in `reasons`.
  THRESHOLDS = [
    [ :cpu, "cpu", :cpu_used_percent, 90, 98 ],
    [ :memory, "memory", :memory_used_percent, 85, 95 ],
    [ :data_root_disk, "data root disk", :data_root_used_percent, DataRootDiskUsage::WARNING_USED_PERCENT, DataRootDiskUsage::CRITICAL_USED_PERCENT ]
  ].freeze
  CPU_PRESSURE_DIMENSION = :cpu_pressure
  CPU_PRESSURE_SOME_WARNING = 20
  CPU_PRESSURE_SOME_CRITICAL = 50
  CPU_PRESSURE_FULL_CRITICAL = 5
  CPU_PRESSURE_CPU_USED_CRITICAL = 90
  IO_PRESSURE_DIMENSION = :io_pressure
  IO_PRESSURE_SOME_WARNING = 20
  IO_PRESSURE_SOME_CRITICAL = 50
  # `some` is the share of time *at least one* task was stalled on IO, so a
  # single process doing one large sequential read or write drives it high on
  # a host that is otherwise fine -- which is exactly what a grader cloning a
  # repository, building, or running a test suite looks like. Escalating on
  # `some` alone turned normal grader work into a critical host: one observed
  # worker read 86% `some` at 0.99% CPU and 7.8% memory, refused further
  # admissions, and its work was rerouted away.
  #
  # `full` is the share of time *every* runnable task was stalled, which is
  # saturation rather than one busy writer. Requiring it mirrors the
  # corroboration CPU pressure already demands, and still escalates a host
  # that is genuinely IO-starved -- the worker above had `full` at 86% too.
  IO_PRESSURE_FULL_CRITICAL = 20

  class << self
    def summarize(samples, fields: NUMERIC_FIELDS, include_sample_count: true)
      samples = samples.compact
      summary = {
        first_observed_at: samples.first&.observed_at&.iso8601,
        last_observed_at: samples.last&.observed_at&.iso8601,
        warning_count: samples.count { |sample| health_for(sample).fetch(:level) == "warning" },
        critical_count: samples.count { |sample| health_for(sample).fetch(:level) == "critical" }
      }
      summary[:sample_count] = samples.length if include_sample_count

      fields.each_with_object(summary) do |field, payload|
        field_summary = numeric_summary(samples, field)
        payload[field] = field_summary if field_summary
      end
    end

    def health_for(sample)
      signals = signals_for(sample)
      level = signals.reduce("ok") { |worst, signal| max_level(worst, signal.fetch(:level)) }

      { level: level, reasons: signals.map { |signal| signal.fetch(:reason) } }
    end

    # The dimension keys that are at `critical`, for a caller that needs to
    # know what is saturated rather than how bad it is overall.
    def critical_dimensions_for(sample)
      signals_for(sample).select { |signal| signal.fetch(:level) == "critical" }.map { |signal| signal.fetch(:dimension) }
    end

    def max_level(left, right)
      LEVEL_ORDER.fetch(left) >= LEVEL_ORDER.fetch(right) ? left : right
    end

    private

    def numeric_summary(samples, field)
      values = samples.filter_map { |sample| sample.public_send(field) }
      return if values.empty?

      {
        avg: (values.sum.to_f / values.length).round(2),
        max: values.max.round(2)
      }
    end

    # One evaluation that both the overall level and the per-dimension view are
    # derived from, in threshold order, so the two can never disagree.
    def signals_for(sample)
      threshold_signals = THRESHOLDS.filter_map do |dimension, label, field, warning, critical|
        threshold_signal(dimension, label, sample.public_send(field), warning: warning, critical: critical)
      end

      threshold_signals + [ io_pressure_signal(sample), cpu_pressure_signal(sample) ].compact
    end

    def threshold_signal(dimension, label, value, warning:, critical:)
      return if value.nil?

      if value >= critical
        signal(dimension, "critical", "#{label} #{value.round(2)}% >= #{critical}%")
      elsif value >= warning
        signal(dimension, "warning", "#{label} #{value.round(2)}% >= #{warning}%")
      end
    end

    def io_pressure_signal(sample)
      some = sample.io_pressure_some
      return if some.nil?

      if some >= IO_PRESSURE_SOME_CRITICAL && io_pressure_corroborated?(sample)
        signal(IO_PRESSURE_DIMENSION, "critical", "IO pressure #{some.round(2)}% >= #{IO_PRESSURE_SOME_CRITICAL}%")
      elsif some >= IO_PRESSURE_SOME_WARNING
        signal(IO_PRESSURE_DIMENSION, "warning", "IO pressure #{some.round(2)}% >= #{IO_PRESSURE_SOME_WARNING}%")
      end
    end

    def cpu_pressure_signal(sample)
      some = sample.cpu_pressure_some
      return if some.nil?

      if some >= CPU_PRESSURE_SOME_CRITICAL && cpu_pressure_corroborated?(sample)
        signal(CPU_PRESSURE_DIMENSION, "critical", "CPU pressure #{some.round(2)}% >= #{CPU_PRESSURE_SOME_CRITICAL}%")
      elsif some >= CPU_PRESSURE_SOME_WARNING
        signal(CPU_PRESSURE_DIMENSION, "warning", "CPU pressure #{some.round(2)}% >= #{CPU_PRESSURE_SOME_WARNING}%")
      end
    end

    def signal(dimension, level, reason)
      { dimension: dimension, level: level, reason: reason }
    end

    def cpu_pressure_corroborated?(sample)
      sample.cpu_pressure_full.to_f >= CPU_PRESSURE_FULL_CRITICAL ||
        sample.cpu_used_percent.to_f >= CPU_PRESSURE_CPU_USED_CRITICAL
    end

    def io_pressure_corroborated?(sample)
      sample.io_pressure_full.to_f >= IO_PRESSURE_FULL_CRITICAL
    end
  end
end
