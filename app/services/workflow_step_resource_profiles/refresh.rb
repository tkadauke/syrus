require "set"

module WorkflowStepResourceProfiles
  class Refresh
    MAX_INPUT_SUMMARIES = 1_000
    SPAN_SAMPLE_MERGE_GAP = 2.minutes
    MAX_SPAN_SAMPLE_RANGES_PER_HOST = 100

    def initialize(now: Time.current)
      @now = now
    end

    def refresh_all!
      refresh_for_summaries!(input_summaries)
      WorkflowStepResourceProfile.stale_as_of(now).delete_all
    end

    def refresh_for_summaries!(summaries)
      summaries = summaries.to_a
      with_summary_metadata(summaries) do
        refresh_profiles!(grouped_inputs(summaries).values)
      end
    end

    private

    attr_reader :now

    def input_summaries
      base = RunResourceSummary
        .where.not(repository_id: nil)
        .where.not(step_kind: nil)
        .where(retention_limited: false)

      recent_finished = base
        .where("finished_at >= ?", now - input_retain_after)
        .order(finished_at: :desc, id: :desc)
        .limit(MAX_INPUT_SUMMARIES)
        .to_a

      remaining = MAX_INPUT_SUMMARIES - recent_finished.size
      return recent_finished unless remaining.positive?

      recent_unfinished = base
        .where(finished_at: nil)
        .where("created_at >= ?", now - input_retain_after)
        .order(created_at: :desc, id: :desc)
        .limit(remaining)
        .to_a

      recent_finished + recent_unfinished
    end

    def input_retain_after
      [ WorkflowStepResourceProfile::INPUT_RETAIN_AFTER, RunResourceSummary::RETAIN_AFTER ].min
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
        run_state(summary).in?(Run::TERMINAL_STATES)
    end

    def profile_key(summary)
      [
        summary.repository_id,
        summary.agent_provider,
        summary.trigger_kind,
        summary.step_kind,
        normalized_grader_name(summary),
        job_kind(summary)
      ]
    end

    def refresh_profiles!(input_groups)
      rows = input_groups.filter_map { |inputs| profile_row(inputs) }
      return if rows.empty?

      WorkflowStepResourceProfile.upsert_all(rows, **profile_upsert_options)
    end

    def profile_upsert_options
      options = { record_timestamps: true }
      if WorkflowStepResourceProfile.connection.supports_insert_conflict_target?
        options[:unique_by] = :idx_workflow_step_resource_profiles_key
      end
      options
    end

    def profile_row(inputs)
      first = inputs.first
      return unless first

      {
        repository_id: first.repository_id,
        agent_provider: first.agent_provider,
        trigger_kind: first.trigger_kind,
        step_kind: first.step_kind,
        grader_name: normalized_grader_name(first),
        job_kind: job_kind(first)
      }.merge(profile_attributes(inputs))
    end

    def profile_attributes(inputs)
      attributed_inputs = attributed_metric_inputs(inputs)

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
        failure_rate: rate(inputs) { |summary| run_state(summary) == "failed" },
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

    def attributed_metric_inputs(inputs)
      inputs.filter_map do |summary|
        attributed_metrics_for(summary)
      end
    end

    def attributed_metrics_for(summary)
      spans = command_spans_for(summary)
      span_metrics = spans.filter_map { |span| attributed_span_metrics(span) }
      return if span_metrics.empty?

      {
        duration_seconds: span_metrics.sum { |metrics| metrics.fetch(:duration_seconds).to_f },
        cpu_pressure: span_metrics.sum { |metrics| metrics.fetch(:cpu_pressure).to_f },
        io_pressure: span_metrics.sum { |metrics| metrics.fetch(:io_pressure).to_f },
        memory_used_percent: span_metrics.map { |metrics| metrics.fetch(:memory_used_percent).to_f }.max
      }
    end

    def attributed_span_metrics(span)
      correlation = WorkerHealthRunCorrelation.for_span(span, sample_limit: 0, now: now, samples_by_hostname: span_samples_by_hostname)
      return if correlation.fetch(:sample_count).zero? || correlation.fetch(:retention_limited)

      {
        duration_seconds: span.duration_s,
        cpu_pressure: correlation.dig(:summary, :cpu_pressure_some, :max),
        io_pressure: correlation.dig(:summary, :io_pressure_some, :max),
        memory_used_percent: correlation.dig(:summary, :memory_used_percent, :max)
      }
    end

    def with_summary_metadata(summaries)
      previous_summaries = @summaries_for_metadata
      previous_job_kinds = @job_kinds_by_id
      previous_run_metadata = @run_metadata_by_id
      previous_step_details = @step_details_by_id
      previous_command_spans = @command_spans_by_run_id
      previous_summary_job_ids = @summary_job_ids
      previous_summary_run_ids = @summary_run_ids
      previous_summary_step_ids = @summary_step_ids
      previous_span_samples = @span_samples_by_hostname

      @summaries_for_metadata = summaries
      @job_kinds_by_id = nil
      @run_metadata_by_id = nil
      @step_details_by_id = nil
      @command_spans_by_run_id = nil
      @summary_job_ids = nil
      @summary_run_ids = nil
      @summary_step_ids = nil
      @span_samples_by_hostname = preload_span_samples_by_hostname(summaries)
      yield
    ensure
      @summaries_for_metadata = previous_summaries
      @job_kinds_by_id = previous_job_kinds
      @run_metadata_by_id = previous_run_metadata
      @step_details_by_id = previous_step_details
      @command_spans_by_run_id = previous_command_spans
      @summary_job_ids = previous_summary_job_ids
      @summary_run_ids = previous_summary_run_ids
      @summary_step_ids = previous_summary_step_ids
      @span_samples_by_hostname = previous_span_samples
    end

    def span_samples_by_hostname
      @span_samples_by_hostname || {}
    end

    def preload_span_samples_by_hostname(summaries)
      ranges_by_hostname = span_sample_ranges_by_hostname(summaries)
      return {} if ranges_by_hostname.empty?

      ranges_by_hostname.each_with_object({}) do |(hostname, ranges), samples_by_hostname|
        samples_by_hostname[hostname] = samples_for_hostname_ranges(hostname, ranges)
      end
    end

    def span_sample_ranges_by_hostname(summaries)
      retained_since = now - WorkerHostHealthSample::RETAIN_AFTER
      intervals_by_hostname = Hash.new { |hash, hostname| hash[hostname] = [] }

      summaries.each do |summary|
        command_spans_for(summary).each do |span|
          next if span.hostname.blank? || span.started_at.blank?

          started_at = [ span.started_at, retained_since ].max
          finished_at = span.finished_at || now
          next if started_at > finished_at

          intervals_by_hostname[span.hostname] << [ started_at, finished_at ]
        end
      end

      intervals_by_hostname.transform_values do |intervals|
        merge_span_sample_intervals(intervals)
      end
    end

    def merge_span_sample_intervals(intervals)
      gap = SPAN_SAMPLE_MERGE_GAP
      merged = merge_intervals(intervals, gap: gap)

      while merged.size > MAX_SPAN_SAMPLE_RANGES_PER_HOST
        gap *= 2
        merged = merge_intervals(intervals, gap: gap)
      end

      merged
    end

    def merge_intervals(intervals, gap:)
      intervals.sort_by(&:first).each_with_object([]) do |(started_at, finished_at), merged|
        if merged.empty? || started_at > merged.last.last + gap
          merged << [ started_at, finished_at ]
        else
          merged.last[1] = [ merged.last.last, finished_at ].max
        end
      end
    end

    def samples_for_hostname_ranges(hostname, ranges)
      base = WorkerHealthRunCorrelation.sample_scope.where(hostname: hostname)
      scoped_ranges = ranges.map { |started_at, finished_at| base.where(observed_at: started_at..finished_at) }
      return [] if scoped_ranges.empty?

      scoped_ranges.reduce { |combined, scope| combined.or(scope) }
        .order(:observed_at)
        .to_a
    end

    def normalized_grader_name(summary)
      summary.step_kind == "grader" ? summary.grader_name.to_s : ""
    end

    def timeout?(summary)
      return true if run_agent_outcome(summary).to_s.match?(/timeout/)
      return true if step_details(summary).is_a?(Hash) && step_details(summary)["timed_out"]

      command_spans_for(summary).any? { |span| span.outcome == "timed_out" }
    end

    def job_kind(summary)
      job_kinds_by_id[summary.job_id].to_s
    end

    def run_state(summary)
      run_metadata_by_id.dig(summary.run_id, :state).to_s
    end

    def run_agent_outcome(summary)
      run_metadata_by_id.dig(summary.run_id, :agent_outcome)
    end

    def step_details(summary)
      step_details_by_id[summary.step_id]
    end

    def command_spans_for(summary)
      command_spans_by_run_id.fetch(summary.run_id, [])
    end

    def job_kinds_by_id
      @job_kinds_by_id ||= begin
        ids = summary_job_ids
        ids.empty? ? {} : Job.where(id: ids).pluck(:id, :kind).to_h
      end
    end

    def run_metadata_by_id
      @run_metadata_by_id ||= begin
        ids = summary_run_ids
        if ids.empty?
          {}
        else
          Run.where(id: ids).pluck(:id, :state, :agent_outcome).to_h do |id, state, agent_outcome|
            [ id, { state: state, agent_outcome: agent_outcome } ]
          end
        end
      end
    end

    def step_details_by_id
      @step_details_by_id ||= begin
        ids = summary_step_ids
        ids.empty? ? {} : Step.where(id: ids).pluck(:id, :details).to_h
      end
    end

    def command_spans_by_run_id
      @command_spans_by_run_id ||= begin
        ids = summary_run_ids
        if ids.empty?
          {}
        else
          CommandSpan.where(run_id: ids)
            .order(:run_id, :sequence, :id)
            .group_by(&:run_id)
        end
      end
    end

    def summary_job_ids
      @summary_job_ids ||= summaries_for_metadata.map(&:job_id).compact.uniq
    end

    def summary_run_ids
      @summary_run_ids ||= summaries_for_metadata.map(&:run_id).compact.uniq
    end

    def summary_step_ids
      @summary_step_ids ||= summaries_for_metadata.map(&:step_id).compact.uniq
    end

    def summaries_for_metadata
      @summaries_for_metadata || []
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
