module WorkflowStepResourceProfiles
  class Refresh
    def initialize(now: Time.current)
      @now = now
    end

    def refresh_all!
      refresh_for_summaries!(input_summaries)
      WorkflowStepResourceProfile.stale_as_of(now).delete_all
    end

    def refresh_for_summaries!(summaries)
      grouped_inputs(summaries).each_value do |inputs|
        refresh_profile!(inputs)
      end
    end

    private

    attr_reader :now

    def input_summaries
      RunResourceSummary
        .includes(:job, :step, run: :command_spans)
        .where.not(repository_id: nil, step_kind: nil)
        .where(retention_limited: false)
        .where("COALESCE(finished_at, created_at) >= ?", now - WorkflowStepResourceProfile::INPUT_RETAIN_AFTER)
    end

    def grouped_inputs(summaries)
      summaries.each_with_object({}) do |summary, groups|
        next unless profile_input?(summary)

        groups[profile_key(summary)] ||= []
        groups[profile_key(summary)] << summary
      end
    end

    def profile_input?(summary)
      summary.repository_id.present? &&
        summary.agent_provider.present? &&
        summary.trigger_kind.present? &&
        summary.step_kind.present? &&
        summary.duration_seconds.present? &&
        summary.run&.state.in?(%w[ succeeded failed cancelled ])
    end

    def profile_key(summary)
      [
        summary.repository_id,
        summary.agent_provider,
        summary.trigger_kind,
        summary.step_kind,
        normalized_grader_name(summary),
        summary.job&.kind.to_s
      ]
    end

    def refresh_profile!(inputs)
      first = inputs.first
      profile = WorkflowStepResourceProfile.find_or_initialize_by(
        repository_id: first.repository_id,
        agent_provider: first.agent_provider,
        trigger_kind: first.trigger_kind,
        step_kind: first.step_kind,
        grader_name: normalized_grader_name(first),
        job_kind: first.job&.kind.to_s
      )

      profile.assign_attributes(profile_attributes(inputs))
      profile.save!
    end

    def profile_attributes(inputs)
      attributed_inputs = process_attributed_metric_inputs(inputs)

      {
        sample_count: inputs.size,
        attributed_sample_count: attributed_inputs.size,
        process_attributed_sample_count: process_attributed_inputs(inputs).size,
        host_pressure_sample_count: host_pressure_inputs(inputs).size,
        attribution_quality: attribution_quality(inputs),
        p50_duration_seconds: percentile(inputs.filter_map(&:duration_seconds), 50),
        p90_duration_seconds: percentile(inputs.filter_map(&:duration_seconds), 90),
        p99_duration_seconds: percentile(inputs.filter_map(&:duration_seconds), 99),
        p50_cpu_pressure: percentile(host_values(inputs, :host_pressure_max_cpu_some_percent), 50),
        p90_cpu_pressure: percentile(host_values(inputs, :host_pressure_max_cpu_some_percent), 90),
        p99_cpu_pressure: percentile(host_values(inputs, :host_pressure_max_cpu_some_percent), 99),
        p50_io_pressure: percentile(host_values(inputs, :host_pressure_max_io_some_percent), 50),
        p90_io_pressure: percentile(host_values(inputs, :host_pressure_max_io_some_percent), 90),
        p99_io_pressure: percentile(host_values(inputs, :host_pressure_max_io_some_percent), 99),
        p50_memory_used_percent: percentile(host_values(inputs, :host_usage_max_memory_used_percent), 50),
        p90_memory_used_percent: percentile(host_values(inputs, :host_usage_max_memory_used_percent), 90),
        p99_memory_used_percent: percentile(host_values(inputs, :host_usage_max_memory_used_percent), 99),
        p50_attributed_duration_seconds: percentile(attributed_inputs.filter_map { |input| input.fetch(:duration_seconds) }, 50),
        p90_attributed_duration_seconds: percentile(attributed_inputs.filter_map { |input| input.fetch(:duration_seconds) }, 90),
        p99_attributed_duration_seconds: percentile(attributed_inputs.filter_map { |input| input.fetch(:duration_seconds) }, 99),
        p50_attributed_cpu_pressure: percentile(attributed_inputs.filter_map { |input| input.fetch(:cpu_pressure) }, 50),
        p90_attributed_cpu_pressure: percentile(attributed_inputs.filter_map { |input| input.fetch(:cpu_pressure) }, 90),
        p99_attributed_cpu_pressure: percentile(attributed_inputs.filter_map { |input| input.fetch(:cpu_pressure) }, 99),
        p50_attributed_io_pressure: percentile(attributed_inputs.filter_map { |input| input.fetch(:io_pressure) }, 50),
        p90_attributed_io_pressure: percentile(attributed_inputs.filter_map { |input| input.fetch(:io_pressure) }, 90),
        p99_attributed_io_pressure: percentile(attributed_inputs.filter_map { |input| input.fetch(:io_pressure) }, 99),
        p50_attributed_memory_used_percent: percentile(attributed_inputs.filter_map { |input| input.fetch(:memory_used_percent) }, 50),
        p90_attributed_memory_used_percent: percentile(attributed_inputs.filter_map { |input| input.fetch(:memory_used_percent) }, 90),
        p99_attributed_memory_used_percent: percentile(attributed_inputs.filter_map { |input| input.fetch(:memory_used_percent) }, 99),
        p50_process_attributed_duration_seconds: percentile(process_values(inputs, :process_attributed_duration_seconds), 50),
        p90_process_attributed_duration_seconds: percentile(process_values(inputs, :process_attributed_duration_seconds), 90),
        p99_process_attributed_duration_seconds: percentile(process_values(inputs, :process_attributed_duration_seconds), 99),
        p50_process_attributed_cpu_seconds: percentile(process_values(inputs, :process_attributed_cpu_seconds), 50),
        p90_process_attributed_cpu_seconds: percentile(process_values(inputs, :process_attributed_cpu_seconds), 90),
        p99_process_attributed_cpu_seconds: percentile(process_values(inputs, :process_attributed_cpu_seconds), 99),
        p50_process_attributed_cpu_percent: percentile(process_values(inputs, :process_attributed_cpu_percent), 50),
        p90_process_attributed_cpu_percent: percentile(process_values(inputs, :process_attributed_cpu_percent), 90),
        p99_process_attributed_cpu_percent: percentile(process_values(inputs, :process_attributed_cpu_percent), 99),
        p50_process_attributed_memory_bytes: percentile(process_values(inputs, :process_attributed_memory_bytes), 50),
        p90_process_attributed_memory_bytes: percentile(process_values(inputs, :process_attributed_memory_bytes), 90),
        p99_process_attributed_memory_bytes: percentile(process_values(inputs, :process_attributed_memory_bytes), 99),
        p50_process_attributed_io_bytes: percentile(process_values(inputs, :process_attributed_io_bytes), 50),
        p90_process_attributed_io_bytes: percentile(process_values(inputs, :process_attributed_io_bytes), 90),
        p99_process_attributed_io_bytes: percentile(process_values(inputs, :process_attributed_io_bytes), 99),
        p50_host_pressure_cpu: percentile(host_values(inputs, :host_pressure_max_cpu_some_percent), 50),
        p90_host_pressure_cpu: percentile(host_values(inputs, :host_pressure_max_cpu_some_percent), 90),
        p99_host_pressure_cpu: percentile(host_values(inputs, :host_pressure_max_cpu_some_percent), 99),
        p50_host_pressure_io: percentile(host_values(inputs, :host_pressure_max_io_some_percent), 50),
        p90_host_pressure_io: percentile(host_values(inputs, :host_pressure_max_io_some_percent), 90),
        p99_host_pressure_io: percentile(host_values(inputs, :host_pressure_max_io_some_percent), 99),
        p50_host_pressure_memory_used_percent: percentile(host_values(inputs, :host_usage_max_memory_used_percent), 50),
        p90_host_pressure_memory_used_percent: percentile(host_values(inputs, :host_usage_max_memory_used_percent), 90),
        p99_host_pressure_memory_used_percent: percentile(host_values(inputs, :host_usage_max_memory_used_percent), 99),
        timeout_rate: rate(inputs) { |summary| timeout?(summary) },
        failure_rate: rate(inputs) { |summary| summary.run&.failed? },
        last_observed_at: inputs.filter_map { |summary| summary.finished_at || summary.created_at }.max,
        profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
      }
    end

    def process_values(inputs, metric)
      process_attributed_inputs(inputs).filter_map { |summary| process_metric(summary, metric) }
    end

    def host_values(inputs, metric)
      host_pressure_inputs(inputs).filter_map { |summary| host_metric(summary, metric) }
    end

    def process_attributed_inputs(inputs)
      inputs.select { |summary| summary.process_sample_count.to_i.positive? }
    end

    def host_pressure_inputs(inputs)
      inputs.select { |summary| summary.host_sample_count.to_i.positive? }
    end

    def process_metric(summary, metric)
      case metric
      when :process_attributed_duration_seconds
        summary.process_wall_time_seconds
      when :process_attributed_cpu_seconds
        summary.process_cpu_time_seconds
      when :process_attributed_cpu_percent
        process_cpu_percent(summary)
      when :process_attributed_memory_bytes
        summary.process_max_rss_bytes
      when :process_attributed_io_bytes
        process_io_bytes(summary)
      else
        summary.public_send(metric)
      end
    end

    def process_io_bytes(summary)
      values = [ summary.process_read_io_bytes, summary.process_write_io_bytes ].compact
      return if values.empty?

      values.sum
    end

    def process_cpu_percent(summary)
      return unless summary.process_cpu_time_seconds && summary.process_wall_time_seconds.to_f.positive?

      (summary.process_cpu_time_seconds.to_f / summary.process_wall_time_seconds.to_f * 100.0).round(1)
    end

    def host_metric(summary, metric)
      case metric
      when :max_cpu_pressure
        summary.host_pressure_max_cpu_some_percent
      when :max_io_pressure
        summary.host_pressure_max_io_some_percent
      when :max_memory_used_percent
        summary.host_usage_max_memory_used_percent
      else
        summary.public_send(metric)
      end
    end

    def attribution_quality(inputs)
      process_count = process_attributed_inputs(inputs).size
      host_count = host_pressure_inputs(inputs).size
      return "defaults_only" if process_count.zero? && host_count.zero?
      return "process_attributed" if process_count == inputs.size
      return "host_correlated" if process_count.zero?

      "mixed"
    end

    def process_attributed_metric_inputs(inputs)
      inputs.filter_map do |summary|
        process_attributed_metrics_for(summary)
      end
    end

    def process_attributed_metrics_for(summary)
      return unless summary.process_attributed_sample_count.to_i.positive?

      {
        duration_seconds: summary.process_attributed_duration_seconds,
        cpu_pressure: summary.process_attributed_cpu_percent,
        io_pressure: nil,
        memory_used_percent: nil
      }
    end

    def normalized_grader_name(summary)
      summary.step_kind == "grader" ? summary.grader_name.to_s : ""
    end

    def timeout?(summary)
      return true if summary.run&.agent_outcome.to_s.match?(/timeout/)
      return true if summary.step&.details.is_a?(Hash) && summary.step.details["timed_out"]

      summary.run&.command_spans&.any? { |span| span.outcome == "timed_out" } || false
    end

    def rate(inputs)
      return 0.0 if inputs.empty?

      (inputs.count { |input| yield input }.to_f / inputs.size).round(4)
    end

    def percentile(values, percentile)
      sorted = values.compact.map(&:to_f).sort
      return nil if sorted.empty?

      index = ((percentile / 100.0) * sorted.size).ceil - 1
      sorted[[ index, 0 ].max]
    end
  end
end
