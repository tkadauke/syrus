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

  THRESHOLDS = [
    [ "cpu", :cpu_used_percent, 90, 98 ],
    [ "memory", :memory_used_percent, 85, 95 ],
    [ "data root disk", :data_root_used_percent, DataRootDiskUsage::WARNING_USED_PERCENT, DataRootDiskUsage::CRITICAL_USED_PERCENT ],
    [ "IO pressure", :io_pressure_some, 20, 50 ]
  ].freeze
  CPU_PRESSURE_SOME_WARNING = 20
  CPU_PRESSURE_SOME_CRITICAL = 50
  CPU_PRESSURE_FULL_CRITICAL = 5
  CPU_PRESSURE_CPU_USED_CRITICAL = 90

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
      level = "ok"
      reasons = []

      THRESHOLDS.each do |label, field, warning, critical|
        level, reasons = apply_threshold(level, reasons, label, sample.public_send(field), warning: warning, critical: critical)
      end
      level, reasons = apply_cpu_pressure_threshold(level, reasons, sample)

      { level: level, reasons: reasons }
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

    def apply_threshold(level, reasons, label, value, warning:, critical:)
      return [ level, reasons ] if value.nil?

      if value >= critical
        [ max_level(level, "critical"), reasons + [ "#{label} #{value.round(2)}% >= #{critical}%" ] ]
      elsif value >= warning
        [ max_level(level, "warning"), reasons + [ "#{label} #{value.round(2)}% >= #{warning}%" ] ]
      else
        [ level, reasons ]
      end
    end

    def apply_cpu_pressure_threshold(level, reasons, sample)
      some = sample.cpu_pressure_some
      return [ level, reasons ] if some.nil?

      if some >= CPU_PRESSURE_SOME_CRITICAL && cpu_pressure_corroborated?(sample)
        [ max_level(level, "critical"), reasons + [ "CPU pressure #{some.round(2)}% >= #{CPU_PRESSURE_SOME_CRITICAL}%" ] ]
      elsif some >= CPU_PRESSURE_SOME_WARNING
        [ max_level(level, "warning"), reasons + [ "CPU pressure #{some.round(2)}% >= #{CPU_PRESSURE_SOME_WARNING}%" ] ]
      else
        [ level, reasons ]
      end
    end

    def cpu_pressure_corroborated?(sample)
      sample.cpu_pressure_full.to_f >= CPU_PRESSURE_FULL_CRITICAL ||
        sample.cpu_used_percent.to_f >= CPU_PRESSURE_CPU_USED_CRITICAL
    end
  end
end
