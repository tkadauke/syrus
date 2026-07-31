class WorkerHealthSampleAnalysis
  NUMERIC_FIELDS = %i[
    cpu_used_percent
    memory_used_percent
    data_root_used_percent
    load_1m
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
    [ "CPU pressure", :cpu_pressure_some, 20, 50 ],
    [ "IO pressure", :io_pressure_some, 20, 50 ]
  ].freeze

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
  end
end
