class RepositoryThroughputMetricContract
  VERSION = 1
  WINDOW_DEFINITIONS = {
    "1h" => 1.hour,
    "4h" => 4.hours,
    "24h" => 24.hours,
    "7d" => 7.days
  }.freeze
  LAST_ACTIVE_WINDOW_DURATION = 1.hour

  OUTPUT_STEP_KINDS = %w[
    implement respond analyze_and_fix landing_fix merge_train_build
    agent_rebase stack_agent_rebase push_agent_rebase
  ].freeze
  LANDING_TRIGGER_KINDS = %w[ auto_merge merge_train ].freeze
  REBASE_TRIGGER_KINDS = %w[ rebase stack_rebase ].freeze
  LANDING_GRADER_STEP_KINDS = %w[ grader_fanout grader grader_collect ].freeze
  MERGEABILITY_REBASE_WAIT_STEP_KINDS = %w[
    mergeability_preflight merge_train_rebase auto_rebase agent_rebase
    stack_auto_rebase stack_agent_rebase
  ].freeze
  LANDING_VALIDATION_CACHED_REASON = "landing_validation_cached".freeze

  def initialize(repository:, now: Time.current)
    @repository = repository
    @now = now
  end

  def call
    {
      version: VERSION,
      repository_id: repository.id,
      generated_at: now.iso8601,
      windows: windows.transform_values { |range| metrics_for(range) }
    }
  end

  private

  attr_reader :repository, :now

  def windows
    WINDOW_DEFINITIONS
      .transform_values { |duration| (now - duration)..now }
      .merge("last_active" => last_active_window)
  end

  def metrics_for(range)
    hours = [(range.end - range.begin) / 1.hour, 1.0 / 60].max
    jobs = jobs_in(range)
    pr_creation = pr_creation_for(range, hours)
    landed_jobs = landed_jobs_in(range)
    landing_attempts = landing_attempts_in(range)
    successful_landing_attempts = landing_attempts.select(&:successful?)
    failed_landing_attempts = landing_attempts.select(&:failed?)
    cancelled_landing_attempts = landing_attempts.select(&:cancelled?)
    deferred_landing_attempts = landing_attempts.select(&:deferred?)
    rebase_workflows = workflows_in(range, trigger_kinds: REBASE_TRIGGER_KINDS)
    output = output_for(range)
    feedback = feedback_for(range)
    approvals = approvals_in(range)
    approval_vote_count = approval_vote_count_in(range)

    {
      range: { start: range.begin.iso8601, end: range.end.iso8601, hours: hours.round(4) },
      pr_creation: pr_creation,
      output: {
        commits: rate_payload(output[:commits], hours, sample_count: output[:commit_sample_count]),
        loc: rate_payload(output[:net_loc], hours, sample_count: output[:diff_sample_count]).merge(
          additions: output[:additions],
          deletions: output[:deletions],
          net: output[:net_loc],
          unavailable_sample_count: output[:unavailable_sample_count]
        ),
        by_job: output[:by_job]
      },
      landing: {
        landing_units: rate_payload(
          successful_landing_attempts.size,
          hours,
          sample_count: successful_landing_attempts.size
        ),
        jobs_landed: rate_payload(
          successful_landing_attempts.sum(&:job_count),
          hours,
          sample_count: successful_landing_attempts.sum(&:job_count)
        ),
        attempts: landing_attempt_payload(landing_attempts, hours),
        unit_types: landing_unit_type_payload(successful_landing_attempts),
        merge_train_size: merge_train_size_payload(successful_landing_attempts),
        approved_to_landing_latency_seconds: duration_payload(approved_to_landing_latencies_for_attempts(successful_landing_attempts)),
        landing_start_to_closed_latency_seconds: duration_payload(landing_start_to_closed_latencies_for_attempts(successful_landing_attempts)),
        grader_phase_duration_seconds: duration_payload(landing_attempts.filter_map(&:grader_phase_seconds)),
        mergeability_rebase_wait_seconds: duration_payload(landing_attempts.filter_map(&:mergeability_rebase_wait_seconds)),
        base_moved_regrade_count: landing_attempts.count(&:base_moved_regrade?),
        reused_landing_validation_count: landing_attempts.count(&:reused_landing_validation?),
        current_optimistic_capacity: optimistic_capacity_payload
      },
      landing_waste: {
        failed_landing_attempts_per_successful_landing: ratio_payload(
          failed_landing_attempts.size + cancelled_landing_attempts.size,
          successful_landing_attempts.size
        ),
        failed_or_cancelled_landing_workflow_seconds: duration_sum((failed_landing_attempts + cancelled_landing_attempts).filter_map(&:workflow)),
        failed_or_cancelled_landing_workflow_count: failed_landing_attempts.size + cancelled_landing_attempts.size,
        deferred_landing_attempt_count: deferred_landing_attempts.size,
        failed_train_cooldown_seconds: failed_train_cooldown_seconds(landing_attempts),
        failed_train_cooldown_remaining_seconds: failed_train_cooldown_remaining_seconds(landing_attempts),
        rebase_churn_workflow_count: rebase_workflows.size,
        rebase_churn_seconds: duration_sum(rebase_workflows),
        landing_blocking_rebase_count: rebase_workflows.count { |workflow| failed_or_cancelled?(workflow) }
      },
      review_funnel: {
        jobs_with_pr_feedback: feedback[:jobs_with_pr_feedback],
        feedback_rounds: feedback[:feedback_rounds],
        jobs_approved_immediately_without_feedback: approved_immediately_without_feedback(approvals),
        approval_latency_seconds: duration_payload(approval_latencies(approvals)),
        approval_to_landing_latency_seconds: duration_payload(approved_to_landing_latencies(landed_jobs)),
        approval_count: approvals.size,
        approval_vote_count: approval_vote_count,
        pr_opened_count: pr_creation[:total_observed_count]
      },
      samples: {
        jobs_seen: jobs.size,
        prs_opened: pr_creation[:total_observed_count],
        output_runs_with_diffs: output[:diff_sample_count],
        landed_jobs: successful_landing_attempts.sum(&:job_count),
        landing_workflows: landing_attempts.count(&:workflow),
        landing_units: successful_landing_attempts.size,
        approvals: approvals.size,
        approval_votes: approval_vote_count,
        feedback_comments: feedback[:comment_count]
      }
    }
  end

  def jobs_in(range)
    repository.jobs.where(created_at: range).to_a
  end

  def pr_creation_for(range, hours)
    jobs_by_source = pr_opened_jobs_in(range).group_by { |job| pr_source_for(job) }
    syrus_authored = jobs_by_source.fetch(:syrus_authored, [])
    external = jobs_by_source.fetch(:external, [])
    fork_review = jobs_by_source.fetch(:fork_review, [])

    rate_payload(syrus_authored.size, hours, sample_count: syrus_authored.size).merge(
      total_observed_count: syrus_authored.size + external.size + fork_review.size,
      series: {
        syrus_authored: rate_payload(syrus_authored.size, hours, sample_count: syrus_authored.size),
        external: rate_payload(external.size, hours, sample_count: external.size),
        fork_review: rate_payload(fork_review.size, hours, sample_count: fork_review.size)
      }
    )
  end

  def pr_opened_jobs_in(range)
    pr_open_steps_in(range).map { |step| step.workflow.job }.uniq
  end

  def pr_open_steps_in(range)
    Step.joins(workflow: :job)
      .where(jobs: { repository_id: repository.id })
      .where(kind: "pr_open", state: "succeeded", finished_at: range)
      .includes(workflow: :job)
      .to_a
      .select do |step|
        step.workflow.job.pr_number.present? ||
          step.workflow.job.external_pr_number.present? ||
          step.workflow.job.fork_review_pr_number.present?
      end
  end

  def pr_source_for(job)
    return :syrus_authored if job.pr_number.present?
    return :external if job.external_pr_number.present?
    return :fork_review if job.fork_review_pr_number.present?

    :unknown
  end

  def landed_jobs_in(range)
    repository.jobs
      .where(state: "closed", closure_reason: %w[ pr_merged external_pr_merged ])
      .where(finished_at: range)
      .includes(:pr_review_comments, :workflows)
      .to_a
  end

  LandingAttempt = Struct.new(
    :unit_type,
    :state,
    :workflow,
    :train,
    :jobs,
    keyword_init: true
  ) do
    def successful? = state == "succeeded"
    def failed? = state == "failed"
    def cancelled? = state == "cancelled"
    def deferred? = cancelled? && jobs.any? { |job| job.state == "approved" }
    def job_count = merge_train? ? jobs.size : 1
    def merge_train? = unit_type == "merge_train"

    def started_at
      candidate = workflow&.started_at || train&.created_at
      return candidate unless candidate && finished_at

      candidate <= finished_at ? candidate : nil
    end

    def finished_at
      workflow&.finished_at || train&.finished_at
    end

    def wall_time_seconds
      return unless started_at && finished_at

      finished_at - started_at
    end

    def grader_phase_seconds
      duration_for_step_kinds(LANDING_GRADER_STEP_KINDS)
    end

    def mergeability_rebase_wait_seconds
      duration_for_step_kinds(MERGEABILITY_REBASE_WAIT_STEP_KINDS)
    end

    def base_moved_regrade?
      return true if workflow&.artifact(Steps::MergeTrainLand::STALE_BASE_ARTIFACT).is_a?(Hash)

      workflow&.steps&.any? { |step| step.kind == "merge_train_rebase" } || false
    end

    def reused_landing_validation?
      workflow&.steps&.any? { |step| step.cancellation_reason == LANDING_VALIDATION_CACHED_REASON } || false
    end

    private

    def duration_for_step_kinds(kinds)
      matching_steps = workflow&.steps&.select { |step| kinds.include?(step.kind) } || []
      started = matching_steps.filter_map(&:started_at).min
      finished = matching_steps.filter_map(&:finished_at).max
      return unless started && finished

      finished - started
    end
  end
  private_constant :LandingAttempt

  def workflows_in(range, trigger_kinds:)
    Workflow.joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(trigger_kind: trigger_kinds)
      .where(finished_at: range)
      .includes(:steps, :job)
      .to_a
  end

  def landing_attempts_in(range)
    auto_merge_attempts = workflows_in(range, trigger_kinds: [ "auto_merge" ]).map do |workflow|
      LandingAttempt.new(
        unit_type: "auto_merge",
        state: workflow.state,
        workflow: workflow,
        jobs: [ workflow.job ]
      )
    end

    train_workflows_by_train_id = Workflow.joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(trigger_kind: "merge_train")
      .where(finished_at: range)
      .includes(:steps, :job)
      .to_a
      .filter_map { |workflow| [ workflow.artifact("merge_train_id").to_i, workflow ] if workflow.artifact("merge_train_id").present? }
      .to_h

    train_attempts = MergeTrain
      .where(repository_id: repository.id, finished_at: range)
      .where(state: %w[ succeeded failed cancelled ])
      .includes(members: :job)
      .map do |train|
        LandingAttempt.new(
          unit_type: "merge_train",
          state: train.state,
          workflow: train_workflows_by_train_id[train.id],
          train: train,
          jobs: train.members.map(&:job)
        )
      end

    auto_merge_attempts + train_attempts
  end

  def output_for(range)
    runs = Run.joins(step: { workflow: :job })
      .where(jobs: { repository_id: repository.id })
      .where(steps: { kind: OUTPUT_STEP_KINDS })
      .where(state: "succeeded", finished_at: range)
      .to_a

    diffs = runs.filter_map { |run| run.step_agent_diff.presence || run.agent_diff.presence }
    loc = diffs.map { |diff| diff_loc(diff) }
    by_job = runs.group_by(&:job).map do |job, job_runs|
      job_diffs = job_runs.filter_map { |run| run.step_agent_diff.presence || run.agent_diff.presence }
      job_loc = job_diffs.map { |diff| diff_loc(diff) }

      {
        job_id: job.id,
        pr_source: pr_source_for(job).to_s,
        pr_number: job.pr_number,
        external_pr_number: job.external_pr_number,
        fork_review_pr_number: job.fork_review_pr_number,
        commit_count: job_runs.filter_map { |run| run.head_sha.presence }.uniq.size,
        sample_count: job_runs.size,
        diff_sample_count: job_diffs.size,
        unavailable_sample_count: job_runs.size - job_diffs.size,
        additions: job_loc.sum { |item| item[:additions] },
        deletions: job_loc.sum { |item| item[:deletions] },
        net: job_loc.sum { |item| item[:additions] - item[:deletions] }
      }
    end.sort_by { |item| item[:job_id] }

    {
      commits: runs.filter_map { |run| run.head_sha.presence }.uniq.size,
      commit_sample_count: runs.count { |run| run.head_sha.present? },
      additions: loc.sum { |item| item[:additions] },
      deletions: loc.sum { |item| item[:deletions] },
      net_loc: loc.sum { |item| item[:additions] - item[:deletions] },
      diff_sample_count: diffs.size,
      unavailable_sample_count: runs.size - diffs.size,
      by_job: by_job
    }
  end

  def diff_loc(diff)
    diff.each_line.each_with_object({ additions: 0, deletions: 0 }) do |line, counts|
      counts[:additions] += 1 if line.start_with?("+") && !line.start_with?("+++")
      counts[:deletions] += 1 if line.start_with?("-") && !line.start_with?("---")
    end
  end

  def feedback_for(range)
    comments = PrReviewComment.joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(comment_created_at: range)
      .to_a

    feedback_workflows = Workflow.joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(trigger_kind: %w[ pr_comment chat_feedback ])
      .where(created_at: range)
      .count

    {
      jobs_with_pr_feedback: comments.map(&:job_id).uniq.size,
      feedback_rounds: feedback_workflows,
      comment_count: comments.size
    }
  end

  def approvals_in(range)
    repository.jobs.where(approved_at: range).includes(:pr_review_comments, :workflows).to_a
  end

  def approved_immediately_without_feedback(approved_jobs)
    approved_jobs.count do |job|
      job.pr_review_comments.none? do |comment|
        comment.comment_created_at.present? &&
          comment.comment_created_at <= job.approved_at
      end
    end
  end

  def approval_vote_count_in(range)
    JobApproval.joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where(approved_at: range)
      .count
  end

  def approval_latencies(approved_jobs)
    approved_jobs.filter_map do |job|
      pr_opened_at = pr_opened_at(job)
      next unless pr_opened_at && job.approved_at

      job.approved_at - pr_opened_at
    end
  end

  def approved_to_landing_latencies(landed_jobs)
    landed_jobs.filter_map do |job|
      landing_started_at = landing_started_at(job)
      next unless landing_started_at && job.approved_at

      landing_started_at - job.approved_at
    end
  end

  def landing_start_to_closed_latencies(landed_jobs)
    landed_jobs.filter_map do |job|
      landing_started_at = landing_started_at(job)
      next unless landing_started_at && job.finished_at

      job.finished_at - landing_started_at
    end
  end

  def approved_to_landing_latencies_for_attempts(attempts)
    attempts.flat_map do |attempt|
      attempt.jobs.filter_map do |job|
        next unless attempt.started_at && job.approved_at
        next if attempt.started_at < job.approved_at

        attempt.started_at - job.approved_at
      end
    end
  end

  def landing_start_to_closed_latencies_for_attempts(attempts)
    attempts.flat_map do |attempt|
      attempt.jobs.filter_map do |job|
        closed_at = job.finished_at || attempt.finished_at
        next unless attempt.started_at && closed_at
        next if closed_at < attempt.started_at

        closed_at - attempt.started_at
      end
    end
  end

  def pr_opened_at(job)
    job.workflows
      .flat_map(&:steps)
      .select { |step| step.kind == "pr_open" && step.succeeded? }
      .filter_map(&:finished_at)
      .min
  end

  def landing_started_at(job)
    job.workflows
      .select { |workflow| LANDING_TRIGGER_KINDS.include?(workflow.trigger_kind) && workflow.succeeded? }
      .filter_map(&:started_at)
      .min
  end

  def landing_attempt_payload(attempts, hours)
    {
      total_count: attempts.size,
      successful: rate_payload(attempts.count(&:successful?), hours, sample_count: attempts.count(&:successful?)),
      failed: rate_payload(attempts.count(&:failed?), hours, sample_count: attempts.count(&:failed?)),
      cancelled: rate_payload(attempts.count(&:cancelled?), hours, sample_count: attempts.count(&:cancelled?)),
      deferred: rate_payload(attempts.count(&:deferred?), hours, sample_count: attempts.count(&:deferred?))
    }
  end

  def landing_unit_type_payload(successful_attempts)
    grouped = successful_attempts.group_by(&:unit_type)
    {
      auto_merge: {
        landing_units: grouped.fetch("auto_merge", []).size,
        jobs_landed: grouped.fetch("auto_merge", []).sum(&:job_count)
      },
      merge_train: {
        landing_units: grouped.fetch("merge_train", []).size,
        jobs_landed: grouped.fetch("merge_train", []).sum(&:job_count)
      }
    }
  end

  def merge_train_size_payload(successful_attempts)
    sizes = successful_attempts.select(&:merge_train?).map(&:job_count)
    {
      sample_count: sizes.size,
      confidence: confidence_for(sizes.size),
      average: average(sizes),
      max: sizes.max,
      values: sizes
    }
  end

  def optimistic_capacity_payload
    attempts = landing_attempts_in((now - 7.days)..now).select(&:successful?)
    timed_attempts = attempts.select { |attempt| attempt.wall_time_seconds&.positive? }
    wall_times = timed_attempts.map(&:wall_time_seconds)
    average_seconds = average(wall_times)
    units_per_hour = average_seconds ? (1.hour.to_f / average_seconds).round(4) : 0.0
    average_jobs_per_unit = timed_attempts.empty? ? nil : (timed_attempts.sum(&:job_count).to_f / timed_attempts.size).round(4)

    {
      sample_count: wall_times.size,
      confidence: confidence_for(wall_times.size),
      average_successful_unit_wall_time_seconds: average_seconds,
      estimated_landing_units_per_hour: units_per_hour,
      estimated_jobs_landed_per_hour: average_jobs_per_unit ? (units_per_hour * average_jobs_per_unit).round(4) : 0.0,
      average_jobs_per_landing_unit: average_jobs_per_unit
    }
  end

  def failed_train_cooldown_seconds(attempts)
    attempts
      .select { |attempt| failed_train_with_cooldown?(attempt) }
      .sum { MergeTrainDispatcher::RETRY_COOLDOWN.to_i }
  end

  def failed_train_cooldown_remaining_seconds(attempts)
    attempts
      .select { |attempt| failed_train_with_cooldown?(attempt) }
      .sum do |attempt|
        next 0 unless attempt.finished_at

        [ attempt.finished_at + MergeTrainDispatcher::RETRY_COOLDOWN - now, 0 ].max
      end.round
  end

  def failed_train_with_cooldown?(attempt)
    attempt.merge_train? &&
      attempt.failed? &&
      !LandingFailureHandler.stale_merge_train_base?(attempt.train&.failure_reason)
  end

  def rate_payload(count, hours, sample_count:)
    {
      count: count,
      per_hour: (count / hours).round(4),
      sample_count: sample_count,
      confidence: confidence_for(sample_count)
    }
  end

  def ratio_payload(numerator, denominator)
    {
      numerator: numerator,
      denominator: denominator,
      value: denominator.positive? ? (numerator.to_f / denominator).round(4) : nil,
      confidence: confidence_for(denominator)
    }
  end

  def duration_payload(values)
    {
      sample_count: values.size,
      confidence: confidence_for(values.size),
      average: average(values),
      p50: percentile(values, 0.50),
      p95: percentile(values, 0.95)
    }
  end

  def duration_sum(records)
    records.sum do |record|
      next 0 unless record.started_at && record.finished_at

      record.finished_at - record.started_at
    end.round
  end

  def average(values)
    return nil if values.empty?

    (values.sum.to_f / values.size).round
  end

  def percentile(values, percentile)
    return nil if values.empty?

    sorted = values.sort
    sorted[((sorted.size - 1) * percentile).ceil].round
  end

  def confidence_for(sample_count)
    case sample_count
    when 0 then "none"
    when 1..4 then "low"
    when 5..19 then "medium"
    else "high"
    end
  end

  def last_active_window
    active_at = [
      repository.jobs.maximum(:created_at),
      Step.joins(workflow: :job).where(jobs: { repository_id: repository.id }).maximum(:finished_at),
      Workflow.joins(:job).where(jobs: { repository_id: repository.id }).maximum(:finished_at),
      PrReviewComment.joins(:job).where(jobs: { repository_id: repository.id }).maximum(:comment_created_at),
    MergeTrain.where(repository_id: repository.id).maximum(:finished_at)
    ].compact.max || now

    (active_at - LAST_ACTIVE_WINDOW_DURATION)..active_at
  end

  def failed_or_cancelled?(record)
    %w[ failed cancelled ].include?(record.state)
  end
end
