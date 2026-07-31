class WorkerHealthRunCorrelation
  SAMPLE_LIMIT = 20
  JOB_RUN_LIMIT = 10
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

  def self.for_run(run, sample_limit: SAMPLE_LIMIT, now: Time.current)
    new(run: run, sample_limit: sample_limit, now: now).as_json
  end

  def self.for_job(job, run_limit: JOB_RUN_LIMIT, now: Time.current)
    runs = job.runs
              .includes(:step, :spawned_processes, step: :workflow)
              .order(created_at: :desc)
              .limit(run_limit)
              .to_a
    summaries = runs.map { |run| new(run: run, sample_limit: 0, now: now).as_json(compact: true) }
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

  def initialize(run:, sample_limit: SAMPLE_LIMIT, now: Time.current)
    @run = run
    @sample_limit = sample_limit.to_i.clamp(0, 100)
    @now = now
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
      processes: process_payloads
    }
    payload[:recent_samples] = recent_samples unless compact || sample_limit.zero?
    payload
  end

  private

  attr_reader :run, :sample_limit, :now

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
    return empty_summary if samples.empty?

    NUMERIC_FIELDS.index_with { |field| numeric_summary(field) }.compact.merge(
      first_observed_at: samples.first.observed_at.iso8601,
      last_observed_at: samples.last.observed_at.iso8601,
      warning_count: samples.count { |sample| sample_health(sample).fetch(:level) == "warning" },
      critical_count: samples.count { |sample| sample_health(sample).fetch(:level) == "critical" }
    )
  end

  def empty_summary
    {
      first_observed_at: nil,
      last_observed_at: nil,
      warning_count: 0,
      critical_count: 0
    }
  end

  def numeric_summary(field)
    values = samples.filter_map { |sample| sample.public_send(field) }
    return if values.empty?

    {
      avg: (values.sum.to_f / values.length).round(2),
      max: values.max.round(2)
    }
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
      health = sample_health(sample)
      level = max_level(level, health.fetch(:level))
      reasons.concat(health.fetch(:reasons))
    end

    {
      level: level,
      reasons: reasons.uniq.first(6)
    }
  end

  def sample_health(sample)
    reasons = []
    level = "ok"
    level, reasons = apply_threshold(level, reasons, "cpu", sample.cpu_used_percent, warning: 90, critical: 98)
    level, reasons = apply_threshold(level, reasons, "memory", sample.memory_used_percent, warning: 85, critical: 95)
    level, reasons = apply_threshold(
      level,
      reasons,
      "data root disk",
      sample.data_root_used_percent,
      warning: DataRootDiskUsage::WARNING_USED_PERCENT,
      critical: DataRootDiskUsage::CRITICAL_USED_PERCENT
    )
    level, reasons = apply_threshold(level, reasons, "CPU pressure", sample.cpu_pressure_some, warning: 20, critical: 50)
    level, reasons = apply_threshold(level, reasons, "IO pressure", sample.io_pressure_some, warning: 20, critical: 50)
    { level: level, reasons: reasons }
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

  def max_level(left, right)
    order = { "unknown" => 0, "ok" => 1, "warning" => 2, "critical" => 3 }
    order.fetch(left) >= order.fetch(right) ? left : right
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
        command: process.command
      }
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
    @processes ||= run.spawned_processes.order(:started_at, :id).to_a
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
end
