require "set"

class WorkerHealthRunCorrelation
  SAMPLE_LIMIT = 20
  JOB_RUN_LIMIT = 10

  def self.for_run(run, sample_limit: SAMPLE_LIMIT, now: Time.current)
    new(run: run, sample_limit: sample_limit, now: now).as_json
  end

  def self.for_span(span, sample_limit: 0, now: Time.current, samples: nil)
    SpanCorrelation.new(span: span, sample_limit: sample_limit, now: now, samples: samples).as_json
  end

  def self.for_job(job, run_limit: JOB_RUN_LIMIT, now: Time.current)
    runs = job.runs
              .select(
                :id,
                :job_id,
                :step_id,
                :state,
                :started_at,
                :finished_at,
                :created_at,
                :updated_at,
                :last_heartbeat_at,
                :agent_turns
              )
              .includes(:step, :spawned_processes, :command_spans, step: :workflow)
              .reorder(created_at: :desc, id: :desc)
              .limit(run_limit)
              .to_a
    samples_by_hostname = preload_samples_by_hostname(runs, now: now)
    summaries = runs.map { |run| new(run: run, sample_limit: 0, now: now, samples_by_hostname: samples_by_hostname).as_json(compact: true) }
    pressured = summaries.select { |summary| %w[warning critical].include?(summary.dig(:pressure, :level)) }

    {
      retained_since: (now - WorkerHostHealthSample::RETAIN_AFTER).iso8601,
      runs_analyzed: runs.size,
      pressure_run_count: pressured.size,
      latest_pressure_runs: pressured.first(5),
      missing_sample_run_count: summaries.count { |summary| summary[:samples_missing] },
      generated_at: now.iso8601
    }
  end

  def self.preload_samples_by_hostname(runs, now:)
    retained_since = now - WorkerHostHealthSample::RETAIN_AFTER
    hostnames = Set.new
    starts = []
    finishes = []

    runs.each do |run|
      run_processes = run.spawned_processes.to_a
      run_spans = run.command_spans.to_a

      ([ run.workflow&.worker_hostname ] + run_processes.map(&:hostname) + run_spans.map(&:hostname)).compact_blank.each { |hostname| hostnames << hostname }

      if (started_at = run.started_at || run.created_at)
        starts << [ started_at, retained_since ].max
        finishes << (run.finished_at || now)
      end

      run_spans.each do |span|
        next if span.hostname.blank? || span.started_at.blank?

        starts << [ span.started_at, retained_since ].max
        finishes << (span.finished_at || now)
      end
    end

    return {} if hostnames.empty? || starts.empty? || finishes.empty?

    WorkerHostHealthSample
      .where(hostname: hostnames.to_a, observed_at: starts.min..finishes.max)
      .order(:hostname, :observed_at)
      .to_a
      .group_by(&:hostname)
  end
  private_class_method :preload_samples_by_hostname

  def initialize(run:, sample_limit: SAMPLE_LIMIT, now: Time.current, samples_by_hostname: nil)
    @run = run
    @sample_limit = sample_limit.to_i.clamp(0, 100)
    @now = now
    @samples_by_hostname = samples_by_hostname
  end

  def as_json(compact: false)
    payload = {
      run_id: run.id,
      job_id: run.job_id,
      workflow_id: run.workflow_id,
      step_id: run.step_id,
      step_kind: run.step&.kind,
      run_state: run.state,
      hostnames: hostnames,
      primary_hostname: primary_hostname,
      range: range_payload,
      sample_count: samples.size,
      samples_missing: samples.empty?,
      retention_limited: retention_limited?,
      summary: summary_payload,
      pressure: pressure_payload,
      processes: process_payloads,
      command_spans: command_span_payloads
    }
    payload[:recent_samples] = recent_samples unless compact || sample_limit.zero?
    payload
  end

  private

  attr_reader :run, :sample_limit, :now, :samples_by_hostname

  def range_payload
    {
      started_at: range_start&.iso8601,
      finished_at: range_finish&.iso8601,
      effective_since: effective_since&.iso8601,
      effective_until: range_finish&.iso8601,
      duration_seconds: range_start && range_finish ? (range_finish - range_start).to_f.round(3) : nil,
      still_running: run.finished_at.blank?,
      retained_since: retained_since.iso8601,
      start_fallback: run.started_at.blank? ? "created_at" : nil
    }.compact
  end

  def summary_payload
    WorkerHealthSampleAnalysis.summarize(samples, include_sample_count: false)
  end

  def pressure_payload
    reasons = []
    level = "ok"

    if hostnames.empty?
      level = "unknown"
      reasons << "no workflow worker hostname or spawned process hostname"
    end

    if samples.empty?
      level = "unknown"
      reasons << "no retained host health samples for run window"
    end

    if retention_limited?
      level = "unknown" if level == "ok"
      reasons << "run started before retained worker health history"
    end

    samples.each do |sample|
      health = WorkerHealthSampleAnalysis.health_for(sample)
      level = WorkerHealthSampleAnalysis.max_level(level, health.fetch(:level))
      reasons.concat(health.fetch(:reasons))
    end

    {
      level: level,
      reasons: reasons.uniq.first(6)
    }
  end

  def process_payloads
    processes.map do |process|
      {
        id: process.id,
        kind: process.kind,
        hostname: process.hostname,
        pid: process.pid,
        outcome: process.outcome,
        started_at: process.started_at&.iso8601,
        finished_at: process.finished_at&.iso8601,
        last_chunk_at: process.last_chunk_at&.iso8601,
        command: CommandRedactor.redact(process.command)
      }
    end
  end

  def command_span_payloads
    command_spans.map do |span|
      SpanCorrelation.new(span: span, sample_limit: 0, now: now, samples_by_hostname: samples_by_hostname).as_json
    end
  end

  def recent_samples
    samples.last(sample_limit).map do |sample|
      {
        id: sample.id,
        hostname: sample.hostname,
        observed_at: sample.observed_at.iso8601,
        cpu_used_percent: sample.cpu_used_percent,
        memory_used_percent: sample.memory_used_percent,
        data_root_used_percent: sample.data_root_used_percent,
        cpu_pressure_some: sample.cpu_pressure_some,
        io_pressure_some: sample.io_pressure_some
      }
    end
  end

  def samples
    @samples ||= begin
      if hostnames.empty? || effective_since.blank? || range_finish.blank?
        []
      elsif samples_by_hostname
        hostnames.flat_map { |hostname| samples_by_hostname.fetch(hostname, []) }
          .select { |sample| sample.observed_at >= effective_since && sample.observed_at <= range_finish }
          .sort_by(&:observed_at)
      else
        WorkerHostHealthSample
          .where(hostname: hostnames, observed_at: effective_since..range_finish)
          .order(:observed_at)
          .to_a
      end
    end
  end

  def hostnames
    @hostnames ||= ([ run.workflow&.worker_hostname ] + processes.map(&:hostname)).compact_blank.uniq
  end

  def primary_hostname
    hostnames.first
  end

  def processes
    @processes ||= begin
      if run.association(:spawned_processes).loaded?
        run.spawned_processes.to_a.sort_by { |process| [ process.started_at || Time.zone.at(0), process.id || 0 ] }
      else
        run.spawned_processes.order(:started_at, :id).to_a
      end
    end
  end

  def command_spans
    @command_spans ||= begin
      if run.association(:command_spans).loaded?
        run.command_spans.to_a.sort_by { |span| [ span.sequence || 0, span.id || 0 ] }
      else
        run.command_spans.ordered.to_a
      end
    end
  end

  def range_start
    @range_start ||= run.started_at || run.created_at
  end

  def range_finish
    @range_finish ||= run.finished_at || now
  end

  def effective_since
    return nil unless range_start

    [ range_start, retained_since ].max
  end

  def retained_since
    @retained_since ||= now - WorkerHostHealthSample::RETAIN_AFTER
  end

  def retention_limited?
    range_start.present? && range_start < retained_since
  end

  class SpanCorrelation
    def initialize(span:, sample_limit:, now:, samples: nil, samples_by_hostname: nil)
      @span = span
      @sample_limit = sample_limit.to_i.clamp(0, 100)
      @now = now
      @samples_override = samples
      @samples_by_hostname = samples_by_hostname
    end

    def as_json
      payload = {
        id: span.id,
        run_id: span.run_id,
        job_id: span.job_id,
        workflow_id: span.workflow_id,
        step_id: span.step_id,
        spawned_process_id: span.spawned_process_id,
        sequence: span.sequence,
        name: span.name,
        command_excerpt: CommandRedactor.redact(span.command_excerpt),
        started_at: span.started_at&.iso8601,
        finished_at: span.finished_at&.iso8601,
        duration_ms: span.duration_ms,
        duration_s: span.duration_s,
        exit_status: span.exit_status,
        outcome: span.outcome,
        hostname: span.hostname,
        metadata: CommandRedactor.redact_value(span.metadata),
        sample_count: samples.size,
        samples_missing: samples.empty?,
        retention_limited: retention_limited?,
        summary: WorkerHealthSampleAnalysis.summarize(samples, include_sample_count: false),
        pressure: pressure_payload
      }
      payload[:recent_samples] = recent_samples if sample_limit.positive?
      payload
    end

    private

    attr_reader :span, :sample_limit, :now, :samples_by_hostname

    def pressure_payload
      reasons = []
      level = "ok"

      if span.hostname.blank?
        level = "unknown"
        reasons << "no command span hostname"
      end

      if span.started_at.blank? || range_finish.blank?
        level = "unknown"
        reasons << "command span has no complete timing window"
      elsif samples.empty?
        level = "unknown"
        reasons << "no retained host health samples for command span window"
      end

      if retention_limited?
        level = "unknown" if level == "ok"
        reasons << "command span started before retained worker health history"
      end

      samples.each do |sample|
        health = WorkerHealthSampleAnalysis.health_for(sample)
        level = WorkerHealthSampleAnalysis.max_level(level, health.fetch(:level))
        reasons.concat(health.fetch(:reasons))
      end

      {
        level: level,
        reasons: reasons.uniq.first(6)
      }
    end

    def samples
      return @samples_override unless @samples_override.nil?

      @samples ||= begin
        if span.hostname.blank? || effective_since.blank? || range_finish.blank?
          []
        elsif samples_by_hostname
          samples_by_hostname.fetch(span.hostname, [])
            .select { |sample| sample.observed_at >= effective_since && sample.observed_at <= range_finish }
        else
          WorkerHostHealthSample
            .where(hostname: span.hostname, observed_at: effective_since..range_finish)
            .order(:observed_at)
            .to_a
        end
      end
    end

    def recent_samples
      samples.last(sample_limit).map do |sample|
        {
          id: sample.id,
          hostname: sample.hostname,
          observed_at: sample.observed_at.iso8601,
          cpu_used_percent: sample.cpu_used_percent,
          memory_used_percent: sample.memory_used_percent,
          data_root_used_percent: sample.data_root_used_percent,
          cpu_pressure_some: sample.cpu_pressure_some,
          io_pressure_some: sample.io_pressure_some
        }
      end
    end

    def range_finish
      span.finished_at || now
    end

    def effective_since
      return nil unless span.started_at

      [ span.started_at, retained_since ].max
    end

    def retained_since
      @retained_since ||= now - WorkerHostHealthSample::RETAIN_AFTER
    end

    def retention_limited?
      span.started_at.present? && span.started_at < retained_since
    end
  end
end
