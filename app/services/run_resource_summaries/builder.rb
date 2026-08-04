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
        sample_confidence: sample_confidence,
        avg_cpu_used_percent: metric(:cpu_used_percent, :avg),
        max_cpu_used_percent: metric(:cpu_used_percent, :max),
        avg_cpu_pressure: metric(:cpu_pressure_some, :avg),
        max_cpu_pressure: metric(:cpu_pressure_some, :max),
        avg_memory_used_percent: metric(:memory_used_percent, :avg),
        max_memory_used_percent: metric(:memory_used_percent, :max),
        avg_io_pressure: metric(:io_pressure_some, :avg),
        max_io_pressure: metric(:io_pressure_some, :max),
        max_data_root_used_percent: metric(:data_root_used_percent, :max),
        spawned_process_count: correlation.fetch(:processes).size,
        command_span_count: correlation.fetch(:command_spans).size,
        resource_pressure_level: correlation.fetch(:pressure).fetch(:level),
        resource_pressure_reasons: correlation.fetch(:pressure).fetch(:reasons),
        retention_limited: correlation.fetch(:retention_limited),
        summary_version: RunResourceSummary::SUMMARY_VERSION
      }
    end

    def metric(name, part)
      correlation.fetch(:summary).dig(name, part)
    end

    def sample_confidence
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

    def grader_name
      return unless step&.kind == "grader"

      step.details["name"].presence
    end
  end
end
