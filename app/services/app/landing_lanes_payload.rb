module App
  class LandingLanesPayload
    HISTORY_LIMIT = 20
    TIMEOUT_FALLBACK_FRACTION = 0.5
    FIXED_PHASE_SECONDS = {
      "assemble" => 15.0,
      "build" => 30.0,
      "prepare" => 30.0,
      "reconcile" => 15.0,
      "collect" => 10.0,
      "land" => 20.0
    }.freeze
    PHASE_ORDER = %w[assemble build prepare reconcile grade collect land].freeze
    TERMINAL_GRADER_STATES = %w[succeeded failed cancelled skipped blocked].freeze

    def self.call(repositories:, jobs:, now: Time.current)
      new(repositories:, jobs:, now:).call
    end

    def initialize(repositories:, jobs:, now:)
      @repositories = repositories.includes(:user).order(:id).to_a
      @jobs = jobs
      @now = now
    end

    def call
      { estimate_kind: "best_case", repositories: @repositories.map { |repository| repository_json(repository) } }
    end

    private

    def repository_json(repository)
      statuses = lane_statuses(repository)
      units = landing_units(statuses)
      visible_job_ids = visible_job_ids_for(repository, units.values)
      units.select! { |_id, unit| visible_job_ids.include?(unit.workflow&.job_id) }
      prime_runtime_history(repository.id, units.values)
      lanes = statuses.map { |status| lane_json(status, units:, visible_job_ids:) }
      {
        id: repository.id,
        slug: repository.slug,
        landing_concurrency: WorkDefinitions.landing_lane_count(repository),
        busy_lane_count: lanes.count { |lane| !lane[:empty] },
        approved_backlog: backlog_json(repository),
        lanes:
      }
    end

    def lane_statuses(repository)
      sample_job = @jobs.where(repository_id: repository.id).where(state: %w[approved landing]).first ||
        @jobs.where(repository_id: repository.id).first
      return empty_lanes(repository) unless sample_job

      WorkDefinitions.landing_lane_status_for(sample_job)
    end

    def landing_units(statuses)
      ids = statuses.filter_map { |status| status[:work_unit_id] }
      WorkUnit.where(id: ids)
        .includes(workflow: [ :job, { steps: :runs } ], work_unit_members: :job)
        .index_by(&:id)
    end

    def visible_job_ids_for(repository, units)
      candidate_ids = units.flat_map do |unit|
        [ unit.workflow&.job_id, *unit.work_unit_members.map(&:job_id) ]
      end.compact.uniq
      @jobs.where(repository_id: repository.id, id: candidate_ids).pluck(:id).to_set
    end

    def empty_lanes(repository)
      (1..WorkDefinitions.landing_lane_count(repository)).map do |lane|
        { lane:, draining: false, occupied: false, work_unit_id: nil }
      end
    end

    def backlog_json(repository)
      LandingQueueProcessor.entries(@jobs.where(repository_id: repository.id, state: "approved"))
        .sort_by(&:position)
        .map do |entry|
          job = entry.job
          { id: job.id, slug: job.slug, app_path: "/jobs/#{job.id}", position: entry.position }
        end
    end

    def lane_json(status, units:, visible_job_ids:)
      unit = units[status[:work_unit_id]]
      return { number: status[:lane], empty: true, draining: status[:draining] } unless unit&.workflow

      workflow = unit.workflow
      members = unit.work_unit_members.sort_by(&:id).filter_map(&:job)
        .select { |job| visible_job_ids.include?(job.id) }
      primary = unit.work_unit_members.find { |member| member.role == "primary" }&.job
      anchor = visible_job_ids.include?(primary&.id) ? primary : workflow.job
      phase = phase_json(workflow)

      {
        number: status[:lane],
        empty: false,
        draining: status[:draining],
        landing_kind: unit.kind,
        anchor_job: job_ref(anchor),
        member_jobs: members.reject { |job| job.id == anchor&.id }.map { |job| job_ref(job) },
        workflow: workflow_ref(workflow),
        **phase
      }
    end

    def job_ref(job)
      return nil unless job

      { id: job.id, slug: job.slug, app_path: "/jobs/#{job.id}" }
    end

    def workflow_ref(workflow)
      {
        id: workflow.id,
        slug: workflow.slug,
        app_path: "/jobs/#{workflow.job_id}?tab=workflows#workflow-#{workflow.id}"
      }
    end

    def phase_json(workflow)
      steps = workflow.steps.to_a.sort_by { |step| [ step.position, step.id ] }
      current = steps.find { |step| %w[running queued].include?(step.state) } || steps.last
      phase = phase_for(current)
      graders = grader_json(workflow, steps)
      estimate = estimate(phase, graders)
      iteration = steps.map(&:iteration).compact.max.to_i

      {
        phase:,
        repair_round: iteration > 1 ? iteration - 1 : nil,
        rebasing: rebasing?(current),
        multisect: multisect_json(steps),
        graders:,
        progress: estimate.fetch(:progress),
        best_case_remaining_seconds: estimate.fetch(:remaining).ceil,
        estimate_kind: "best_case"
      }
    end

    def phase_for(step)
      kind = step&.kind.to_s
      return "grade" if kind == "grader" || kind.include?("grader_fanout")
      return "collect" if kind.include?("collect")
      return "land" if kind == "land" || kind.end_with?("_land") || kind.end_with?("_merge")
      return "prepare" if kind.include?("prepare")
      return "build" if kind.include?("build")
      return "reconcile" if kind.include?("reconcile") || kind.include?("repair") || kind.include?("rebase")

      "assemble"
    end

    def rebasing?(step)
      step&.kind.to_s.include?("rebase") || step&.details.to_h["rebasing"] == true
    end

    def multisect_json(steps)
      active = steps.select { |step| step.kind == "merge_train_multisect_evaluate" && !step.state.in?(TERMINAL_GRADER_STATES) }
      return nil if active.empty?

      {
        sub_lanes: active.map do |step|
          { step_id: step.id, role: step.details.to_h["role"], round: step.details.to_h["round"], state: step.state }
        end
      }
    end

    def grader_json(workflow, steps)
      carried = Array(workflow.artifact(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY)).index_by { |entry| entry["name"].to_s }
      active_iteration = steps.select { |step| step.kind == "grader" }.map(&:iteration).compact.max
      active = steps.select { |step| step.kind == "grader" && (active_iteration.nil? || step.iteration == active_iteration) }
      current_names = active.map { |step| step.details.to_h["name"].to_s }
      rows = active.map { |step| grader_step_json(workflow, step) }
      rows.concat(carried.except(*current_names).values.map { |entry| carried_grader_json(entry) })
      rows
    end

    def grader_step_json(workflow, step)
      details = step.details.to_h
      name = details["name"].to_s
      expected = expected_grader_seconds(workflow.job.repository_id, name, details["timeout_minutes"])
      elapsed = elapsed_seconds(step)
      completed = TERMINAL_GRADER_STATES.include?(step.state)
      {
        name:, state: step.state, carried: false,
        expected_seconds: expected.round(1),
        progress: completed ? 1.0 : (step.state == "running" ? [ elapsed / expected, 0.99 ].min.round(4) : 0.0)
      }
    end

    def carried_grader_json(entry)
      { name: entry["name"].to_s, state: "carried", carried: true, expected_seconds: 0.0, progress: 1.0 }
    end

    def expected_grader_seconds(repository_id, name, timeout_minutes)
      durations = @runtime_history&.fetch([ repository_id, name ], nil)
      return median(durations) if durations&.any?

      [ timeout_minutes.to_f.minutes * TIMEOUT_FALLBACK_FRACTION, 1.0 ].max
    end

    def prime_runtime_history(repository_id, units)
      names = units.flat_map do |unit|
        unit.workflow.steps.filter_map do |step|
          step.details.to_h["name"].to_s if step.kind == "grader"
        end
      end.uniq
      return if names.empty?

      ranked = GraderConclusion.where(repository_id:, grader_name: names, status: "passed")
        .where.not(duration_s: nil)
        .select(
          :grader_name,
          :duration_s,
          Arel.sql("ROW_NUMBER() OVER (PARTITION BY grader_name ORDER BY checked_at DESC) AS runtime_rank")
        )
      rows = GraderConclusion.from(ranked, :grader_conclusions)
        .where("runtime_rank <= ?", HISTORY_LIMIT)
        .pluck(:grader_name, :duration_s)

      @runtime_history ||= {}
      rows.group_by(&:first).each do |name, grader_rows|
        @runtime_history[[ repository_id, name ]] = grader_rows.map { |row| row.last.to_f }.sort
      end
    end

    def median(values)
      middle = values.length / 2
      values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
    end

    def elapsed_seconds(step)
      return 0.0 unless step.started_at

      [ (@now - step.started_at).to_f, 0.0 ].max
    end

    def estimate(phase, graders)
      active_graders = graders.reject { |grader| grader[:carried] }
      grade_total = active_graders.sum { |grader| grader[:expected_seconds] }
      fixed_total = FIXED_PHASE_SECONDS.values.sum
      total = fixed_total + grade_total
      phase_index = PHASE_ORDER.index(phase) || 0
      completed_fixed = PHASE_ORDER.first(phase_index).sum { |name| FIXED_PHASE_SECONDS.fetch(name, 0.0) }
      grade_done = active_graders.sum { |grader| grader[:expected_seconds] * grader[:progress] }
      completed_grade = phase_index > PHASE_ORDER.index("grade") ? grade_total : 0.0
      current_fixed = FIXED_PHASE_SECONDS.fetch(phase, 0.0)
      current_elapsed = phase == "grade" ? grade_done : [ current_fixed, 0.0 ].max * 0.5
      progress = total.positive? ? ((completed_fixed + completed_grade + current_elapsed) / total).clamp(0.0, 1.0) : 0.0

      grader_remaining = active_graders.map do |grader|
        grader[:expected_seconds] * (1.0 - grader[:progress])
      end.max.to_f
      remaining_fixed = PHASE_ORDER.drop(phase_index + 1).sum { |name| FIXED_PHASE_SECONDS.fetch(name, 0.0) }
      pending_grade = phase_index < PHASE_ORDER.index("grade") ? active_graders.map { |grader| grader[:expected_seconds] }.max.to_f : 0.0
      remaining = phase == "grade" ? grader_remaining + remaining_fixed : current_fixed + remaining_fixed + pending_grade
      { progress: progress.round(4), remaining: }
    end
  end
end
