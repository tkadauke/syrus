module SdlcPipeline
  class History
    DEFAULT_RANGE = 7.days
    MAX_RANGE = 90.days
    MAX_JOBS = 500
    MAX_DELTAS = 2_000

    def initialize(repository:, user:, filter:, from: nil, to: nil, now: Time.current)
      @repository = repository
      @user = user
      @filter = filter
      @now = now
      @to = [ parse_time(to) || now, now ].min
      requested_from = parse_time(from) || (@to - DEFAULT_RANGE)
      @from = [ [ requested_from, @to ].min, @to - MAX_RANGE ].max
    end

    def call
      entries = Stage.entries(RepoDeploymentStagesReader.for_repository(repository).stages)
      job_scope = filter.apply(Job.visible_to(user)).where(repository_id: repository.id)
        .where("jobs.created_at <= ?", to).includes(:epic, :deployment_stage_statuses)
        .order(created_at: :asc, id: :asc)
      jobs = job_scope.limit(MAX_JOBS + 1).to_a
      jobs_truncated = jobs.length > MAX_JOBS
      jobs = jobs.first(MAX_JOBS)
      transitions = StateTransition.where(subject_type: "Job", subject_id: jobs.map(&:id))
        .where("created_at <= ?", to).order(:created_at, :id).to_a.group_by(&:subject_id)

      checkpoint = jobs.filter_map do |job|
        stage = stage_at(job, from, entries, transitions.fetch(job.id, []))
        placement(job, stage) if stage
      end
      deltas = jobs.flat_map do |job|
        event_times(job, transitions.fetch(job.id, [])).filter_map do |time|
          before = stage_at(job, time - 0.000001.seconds, entries, transitions.fetch(job.id, []))
          after = stage_at(job, time, entries, transitions.fetch(job.id, []))
          next if before&.key == after&.key

          {
            at: time.iso8601(6), job_id: job.id, from_stage: before&.key,
            to_stage: after&.key, item: after && placement(job, after)
          }
        end
      end.sort_by { |delta| delta[:at] }
      deltas_truncated = deltas.length > MAX_DELTAS
      deltas = deltas.first(MAX_DELTAS)
      effective_to = deltas_truncated ? Time.zone.parse(deltas.last[:at]) : to
      traces = trace_payload(checkpoint, deltas, effective_to)
      legacy_jobs = jobs.select { |job| legacy_gap_in_range?(job, transitions.fetch(job.id, [])) }
      inconsistent_evidence = deltas.empty? && jobs.any? do |job|
        stage_changing_evidence_in_range?(job, entries, transitions.fetch(job.id, []))
      end
      incomplete = deltas.empty? && (legacy_jobs.any? || inconsistent_evidence)

      {
        from: from.iso8601,
        to: effective_to.iso8601,
        checkpoint: { at: from.iso8601, placements: checkpoint },
        deltas: deltas,
        ticks: deltas.map { |delta| delta[:at] }.uniq,
        traces: traces,
        bounds: {
          maximum_days: (MAX_RANGE / 1.day).to_i, maximum_jobs: MAX_JOBS, maximum_deltas: MAX_DELTAS,
          included_jobs: jobs.length, omitted_jobs: jobs_truncated ? job_scope.count - jobs.length : 0
        },
        accuracy: {
          status: accuracy_status(jobs_truncated:, deltas_truncated:, incomplete:, legacy_jobs:),
          message: accuracy_message(jobs_truncated:, deltas_truncated:, incomplete:),
          truncated: jobs_truncated || deltas_truncated,
          legacy_job_count: legacy_jobs.length
        }
      }
    end

    private

    attr_reader :repository, :user, :filter, :from, :to, :now

    def parse_time(value)
      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end

    def event_times(job, transitions)
      times = transitions.filter_map { |transition| transition.created_at if transition.created_at.between?(from, to) }
      times << job.created_at if job.created_at.between?(from, to)
      times << job.finished_at if job.finished_at&.between?(from, to)
      job.deployment_stage_statuses.each { |status| times << status.reached_at if status.reached_at.between?(from, to) }
      times.uniq.sort
    end

    def legacy_gap_in_range?(job, transitions)
      transitions.empty? && job.updated_at > job.created_at && job.updated_at.between?(from, to)
    end

    # This is a consistency guard, not another reconstruction source. If durable
    # evidence says an included Job crossed a visible stage in the requested
    # window, returning a normal empty envelope would hide a reconstruction bug.
    def stage_changing_evidence_in_range?(job, entries, transitions)
      transitions.any? do |transition|
        transition.created_at.between?(from, to) &&
          lifecycle_key(transition.from_state) != lifecycle_key(transition.to_state)
      end ||
        (job.created_at.between?(from, to) && stage_at(job, job.created_at, entries, transitions).present?) ||
        (job.finished_at&.between?(from, to) && landed_at?(job, job.finished_at)) ||
        job.deployment_stage_statuses.any? { |status| status.reached_at.between?(from, to) }
    end

    def stage_at(job, at, entries, transitions)
      return if job.created_at > at

      deployment = job.deployment_stage_statuses.select { |status| status.reached_at <= at }.max_by(&:reached_at)
      return entries.find { |entry| entry.key == "deployment:#{deployment.stage_name}" } if deployment
      return entries.find { |entry| entry.key == "landed" } if landed_at?(job, at)

      following = transitions.find { |transition| transition.created_at > at }
      preceding = transitions.reverse_each.find { |transition| transition.created_at <= at }
      state = following&.from_state || (job.finished_at && at < job.finished_at ? preceding&.to_state : nil) || job.state
      key = lifecycle_key(state)
      entries.find { |entry| entry.key == key }
    end

    def landed_at?(job, at)
      job.finished_at && job.finished_at <= at &&
        (job.landed_sha.present? || job.no_change_needed? || Epic::SUCCESSFUL_JOB_CLOSURE_REASONS.include?(job.closure_reason))
    end

    def lifecycle_key(state)
      return "triaging" if %w[triaging].include?(state)
      return "ready" if %w[backlog queued].include?(state)
      return "implementing" if %w[running coding failed].include?(state)
      return "review" if state == "implemented"
      return "landing" if %w[approved landing].include?(state)

      nil
    end

    def placement(job, stage)
      {
        job_id: job.id,
        stage: stage.key,
        item: {
          id: job.id, slug: job.slug, title: job.issue_title, state: job.state,
          epic: job.epic && { id: job.epic.id, slug: job.epic.slug, title: job.epic.title },
          paths: { job: "/jobs/#{job.slug}" }, metadata_as_of: now.iso8601
        }
      }
    end

    def trace_payload(checkpoint, deltas, trace_to)
      initial = checkpoint.index_by { |placement| placement[:job_id] }
      (initial.keys | deltas.map { |delta| delta[:job_id] }).filter_map do |job_id|
        entered_at = from
        stage = initial.dig(job_id, :stage)
        segments = []
        deltas.select { |delta| delta[:job_id] == job_id }.each do |delta|
          left_at = Time.zone.parse(delta[:at])
          segments << trace_segment(stage, entered_at, left_at) if stage
          stage = delta[:to_stage]
          entered_at = left_at
        end
        segments << trace_segment(stage, entered_at, trace_to) if stage
        { job_id: job_id, segments: segments } if segments.any?
      end
    end

    def trace_segment(stage, entered_at, left_at)
      { stage: stage, entered_at: entered_at.iso8601, left_at: left_at.iso8601, dwell_seconds: (left_at - entered_at).to_i }
    end

    def accuracy_status(jobs_truncated:, deltas_truncated:, incomplete:, legacy_jobs:)
      return "bounded" if jobs_truncated || deltas_truncated
      return "incomplete" if incomplete
      return "partial" if legacy_jobs.any?

      "reconstructed"
    end

    def accuracy_message(jobs_truncated:, deltas_truncated:, incomplete:)
      return "Historical evidence exists in this window, but it is not complete enough to reconstruct stage changes safely." if incomplete

      detail = if jobs_truncated
        " The cohort exceeds the job bound; only the earliest bounded cohort is shown."
      elsif deltas_truncated
        " The range ends at the last complete event because the delta bound was reached."
      else
        ""
      end
      "Stage placement is reconstructed from recorded transitions and delivery timestamps; legacy gaps fall back to current state. Card metadata is current.#{detail}"
    end
  end
end
