module Admin
  class ResourceAdmissionDiagnosticsPayload
    ACTIVE_LIMIT = 8
    RECENT_LIMIT = 8
    DELAYED_LIMIT = 8
    LOW_CONFIDENCE_LIMIT = 10
    OVERRIDE_LIMIT = 8
    RECENT_WINDOW = 24.hours
    DELAYED_WINDOW = 6.hours

    def initialize(now: Time.current)
      @now = now
    end

    def as_json(*)
      {
        generated_at: now.iso8601,
        windows: {
          recent_hours: (RECENT_WINDOW / 1.hour).to_i,
          delayed_hours: (DELAYED_WINDOW / 1.hour).to_i
        },
        active_consumers: active_consumers,
        recent_top_consumers: recent_top_consumers,
        delayed_work: delayed_work,
        low_confidence_profiles: low_confidence_profiles,
        admission_overrides: admission_overrides
      }
    end

    private

    attr_reader :now

    def active_consumers
      runs = Run.where(state: "running")
        .includes(:run_resource_summary, { job: :repository }, step: :workflow)
        .order(Arel.sql("COALESCE(runs.started_at, runs.created_at) ASC"))
        .limit(ACTIVE_LIMIT)

      runs.map { |run| serialize_active_run(run) }
    end

    def recent_top_consumers
      summaries = recent_summary_scope
        .order(Arel.sql("COALESCE(process_attributed_duration_seconds, process_wall_time_seconds, duration_seconds, 0) DESC"))
        .limit(RECENT_LIMIT)

      summaries.map { |summary| serialize_summary(summary) }
    end

    def delayed_work
      workflows = Workflow.where(state: "queued")
        .includes(:job)
        .where("artifacts LIKE ?", "%#{StepDispatcher::ADMISSION_BLOCK_REASON}%")
        .where("updated_at >= ?", now - DELAYED_WINDOW)
        .order(updated_at: :desc)
        .limit(DELAYED_LIMIT)

      workflows.select { |workflow| workflow.artifact("start_blocked_reason") == StepDispatcher::ADMISSION_BLOCK_REASON }
        .map { |workflow| serialize_delayed_workflow(workflow) }
    end

    def low_confidence_profiles
      WorkflowStepResourceProfile
        .includes(:repository)
        .where(confidence_levels_clause)
        .order(:sample_count, :attributed_sample_count, :repository_id, :step_kind, :grader_name)
        .limit(LOW_CONFIDENCE_LIMIT)
        .map { |profile| serialize_profile(profile) }
    end

    def admission_overrides
      workflows = Workflow.includes(:job)
        .where("artifacts LIKE ?", "%\"workflow_admission_override\"%")
        .order(updated_at: :desc)
        .limit(OVERRIDE_LIMIT)

      workflows.map { |workflow| serialize_override(workflow) }
    end

    def recent_summary_scope
      RunResourceSummary
        .includes(:run, :job, :workflow, :step, :repository)
        .where("COALESCE(finished_at, started_at, created_at) >= ?", now - RECENT_WINDOW)
    end

    def confidence_levels_clause
      threshold = WorkflowStepResourceProfile::NORMAL_ADMISSION_SAMPLE_COUNT
      [
        "sample_count < :threshold OR attributed_sample_count < :threshold OR process_attributed_sample_count < :threshold",
        { threshold: threshold }
      ]
    end

    def serialize_active_run(run)
      summary = run.run_resource_summary
      workflow = run.step&.workflow
      {
        run_id: run.id,
        job_id: run.job_id,
        workflow_id: workflow&.id,
        step_kind: run.step&.kind,
        grader_name: grader_name_for(run.step),
        repository: run.job&.repository&.slug,
        host: summary&.hostname,
        state: run.state,
        started_at: iso8601(run.started_at),
        wall_time_seconds: elapsed_seconds(run.started_at, now),
        heartbeat_age_seconds: elapsed_seconds(run.last_heartbeat_at, now),
        job: job_payload(run.job),
        workflow_path: workflow_path(workflow),
        pressure: summary ? pressure_payload(summary) : nil,
        estimated_remaining_cost: admission_estimate_for(workflow)
      }
    end

    def serialize_summary(summary)
      {
        run_id: summary.run_id,
        job_id: summary.job_id,
        workflow_id: summary.workflow_id,
        step_kind: summary.step_kind,
        grader_name: summary.grader_name,
        repository: summary.repository&.slug,
        host: summary.hostname,
        finished_at: iso8601(summary.finished_at),
        wall_time_seconds: numeric(summary.process_attributed_duration_seconds || summary.process_wall_time_seconds || summary.duration_seconds),
        job: job_payload(summary.job),
        workflow_path: workflow_path(summary.workflow),
        pressure: pressure_payload(summary),
        prediction: prediction_payload_for(summary)
      }
    end

    def serialize_delayed_workflow(workflow)
      details = workflow.artifact("start_blocked_details") || {}
      {
        workflow_id: workflow.id,
        job_id: workflow.job_id,
        trigger_kind: workflow.trigger_kind,
        reason: details["reason"],
        action: details["action"],
        delay_until: details["delay_until"],
        delayed_at: workflow.artifact("start_blocked_at"),
        next_check_at: workflow.artifact("start_blocked_next_check_at"),
        job: job_payload(workflow.job),
        workflow_path: workflow_path(workflow),
        decision: compact_decision(details),
        pressure: details["pressure"],
        estimated_remaining_cost: details.dig("pressure", "candidate", "predicted_command_cost"),
        details: details["details"] || {}
      }
    end

    def serialize_profile(profile)
      prediction = profile.conservative_prediction
      {
        id: profile.id,
        repository: profile.repository&.slug,
        agent_provider: profile.agent_provider,
        trigger_kind: profile.trigger_kind,
        job_kind: profile.job_kind,
        step_kind: profile.step_kind,
        grader_name: profile.grader_name.presence,
        confidence_level: prediction.fetch(:confidence_level),
        attribution_confidence_level: prediction.fetch(:attribution_confidence_level),
        attribution_quality: prediction.fetch(:attribution_quality),
        sample_count: profile.sample_count,
        attributed_sample_count: profile.attributed_sample_count,
        process_attributed_sample_count: profile.process_attributed_sample_count,
        host_pressure_sample_count: profile.host_pressure_sample_count,
        prediction_source: prediction.fetch(:prediction_source),
        fallback_reason: prediction.fetch(:fallback_reason),
        predicted_command_cost: command_cost_payload(prediction),
        last_observed_at: iso8601(profile.last_observed_at)
      }
    end

    def serialize_override(workflow)
      override = workflow.artifact("workflow_admission_override") || {}
      {
        workflow_id: workflow.id,
        job_id: workflow.job_id,
        trigger_kind: workflow.trigger_kind,
        reason: override["reason"],
        action: override["action"],
        override: override["override"],
        decided_at: workflow.artifact("workflow_admission_decided_at"),
        job: job_payload(workflow.job),
        workflow_path: workflow_path(workflow),
        decision: compact_decision(override),
        pressure: override["pressure"],
        estimated_remaining_cost: override.dig("pressure", "candidate", "predicted_command_cost"),
        details: override["details"] || {}
      }
    end

    def prediction_payload_for(summary)
      profile = profile_for(summary)
      return nil unless profile

      prediction = profile.conservative_prediction
      {
        confidence_level: prediction.fetch(:confidence_level),
        attribution_confidence_level: prediction.fetch(:attribution_confidence_level),
        sample_count: profile.sample_count,
        attributed_sample_count: profile.attributed_sample_count,
        prediction_source: prediction.fetch(:prediction_source),
        fallback_reason: prediction.fetch(:fallback_reason)
      }
    end

    def profile_for(summary)
      WorkflowStepResourceProfile.find_by(
        repository_id: summary.repository_id,
        agent_provider: summary.agent_provider,
        trigger_kind: summary.trigger_kind,
        job_kind: summary.job&.kind.to_s,
        step_kind: summary.step_kind.to_s,
        grader_name: summary.grader_name.to_s
      )
    end

    def pressure_payload(summary)
      {
        cpu_pressure: numeric(summary.host_pressure_max_cpu_some_percent),
        io_pressure: numeric(summary.host_pressure_max_io_some_percent),
        memory_used_percent: numeric(summary.host_usage_max_memory_used_percent),
        host_pressure_level: summary.host_pressure_level,
        host_pressure_reasons: summary.host_pressure_reasons || [],
        host_sample_count: summary.host_sample_count,
        host_sample_confidence: summary.host_sample_confidence,
        process_attribution_confidence: summary.process_attribution_confidence,
        process_attribution_method: summary.process_attribution_method,
        process_sample_count: summary.process_sample_count,
        process_attributed_sample_count: summary.process_attributed_sample_count,
        process_cpu_seconds: numeric(summary.process_attributed_cpu_seconds || summary.process_cpu_time_seconds),
        process_io_bytes: summary.process_attributed_io_bytes || total_process_io(summary),
        process_memory_bytes: summary.process_attributed_memory_bytes || summary.process_max_rss_bytes
      }
    end

    def total_process_io(summary)
      return nil if summary.process_read_io_bytes.nil? && summary.process_write_io_bytes.nil?

      summary.process_read_io_bytes.to_i + summary.process_write_io_bytes.to_i
    end

    def compact_decision(payload)
      {
        action: payload["action"],
        reason: payload["reason"],
        override: payload["override"],
        delay_until: payload["delay_until"]
      }.compact
    end

    def admission_estimate_for(workflow)
      return nil unless workflow

      decision = workflow.artifact("workflow_admission_decision") || workflow.artifact("start_blocked_details")
      decision&.dig("pressure", "candidate", "predicted_command_cost")
    end

    def command_cost_payload(prediction)
      {
        duration_seconds: numeric(prediction.fetch(:duration_seconds)),
        cpu_pressure: numeric(prediction.fetch(:cpu_pressure)),
        io_pressure: numeric(prediction.fetch(:io_pressure)),
        memory_used_percent: numeric(prediction.fetch(:memory_used_percent))
      }
    end

    def job_payload(job)
      return nil unless job

      {
        id: job.id,
        slug: job.slug,
        title: job.issue_title,
        state: job.state,
        priority: job.priority,
        path: "/jobs/#{job.id}"
      }
    end

    def workflow_path(workflow)
      workflow ? App::WorkflowNavigation.path(workflow) : nil
    end

    def grader_name_for(step)
      return nil unless step&.kind == "grader"

      step.details.to_h["name"].presence
    end

    def elapsed_seconds(started_at, ended_at)
      return nil unless started_at && ended_at

      (ended_at - started_at).round
    end

    def numeric(value)
      value&.to_f&.round(2)
    end

    def iso8601(value)
      value&.iso8601
    end
  end
end
