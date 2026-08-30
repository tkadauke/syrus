class RunCompletionReconciler
  Result = Data.define(:reconciled, :reason) do
    def reconciled? = reconciled
  end

  PR_OPENED_PATTERN = /pr_open: opened PR #(?<number>\d+)/.freeze
  EXISTING_PR_PUSHED_PATTERN = /pr_open: branch pushed for existing PR #(?<number>\d+)/.freeze
  TERMINAL_RECOVERY_STEP_KINDS = %w[
    auto_merge
    external_pr_merge
    merge_train_land
    merge_train_land_after_rebase
  ].freeze

  def self.call(...) = new(...).call

  def initialize(run, allow_terminal_recovery: false)
    @run = run
    @step = run.step
    @workflow = @step&.workflow
    @job = run.job
    @allow_terminal_recovery = allow_terminal_recovery
  end

  def call
    return unreconciled unless recoverable_state?(run, :run)
    return unreconciled unless recoverable_state?(step, :step)
    return unreconciled unless recoverable_state?(workflow, :workflow)

    strategy = Step::Kind.fetch(step.kind).reconcile_strategy
    return unreconciled unless strategy
    return unreconciled unless terminal_recovery_allowed?

    send(:"reconcile_#{strategy}")
  rescue ArgumentError
    unreconciled
  end

  private

  attr_reader :run, :step, :workflow, :job

  def terminal_recovery_allowed?
    return true unless allow_terminal_recovery
    return true if TERMINAL_RECOVERY_STEP_KINDS.include?(step.kind)

    @unreconciled_reason = "#{step.kind} is not eligible for terminal recovery"
    false
  end

  def recoverable_state?(record, label)
    return true if record&.running?
    return false unless allow_terminal_recovery
    return false unless record

    if record.cancelled?
      true
    elsif record.terminal?
      @unreconciled_reason = "#{label} is #{record.state}, not running or cancelled"
      false
    else
      @unreconciled_reason = "#{label} is #{record.state}, not running"
      false
    end
  end

  def reconcile_pr_open
    event = pr_open_completion_event
    return unreconciled unless event

    pr_number = event.fetch(:pr_number)
    if job.pr_number.blank?
      job.update!(
        pr_number: pr_number,
        branch_name: job.branch_name.presence || WorkflowWorkspace.new(workflow).branch_name
      )
    end

    return unreconciled unless job.reload.pr_number.to_i == pr_number

    mark_run_succeeded!
    sync_step_from_run!

    # after_commit normally advances the workflow. Keep an explicit
    # backstop for reaper paths and tests where the callback may be delayed.
    StepDispatcher.advance_from(step.reload) if workflow.reload.running?
    finish_workflow_if_terminal!

    Result.new(reconciled: true, reason: event.fetch(:reason))
  end

  def pr_open_completion_event
    run.job_logs.reorder(sequence: :desc).pluck(:chunk).each do |chunk|
      text = chunk.to_s

      if (match = text.match(PR_OPENED_PATTERN))
        return {
          pr_number: match[:number].to_i,
          reason: "pr_open already opened PR ##{match[:number]}"
        }
      end

      if (match = text.match(EXISTING_PR_PUSHED_PATTERN))
        return {
          pr_number: match[:number].to_i,
          reason: "pr_open already pushed existing PR ##{match[:number]}"
        }
      end
    end

    nil
  end

  def reconcile_auto_merge
    pr_number = job.pr_number
    return unreconciled unless pr_number.present?

    if job.closed? && job.closure_reason == "pr_merged"
      recover_success!("auto_merge: PR ##{pr_number} already closed as merged by Syrus")
      return Result.new(reconciled: true, reason: "auto_merge: PR ##{pr_number} already closed as merged by Syrus")
    end

    client = GithubClient.for(repository: job.repository, user: job.user)
    pr = client.pull_request(job.repository.slug, pr_number, bypass_cache: true)
    return unreconciled unless pr[:merged]

    recover_success!("auto_merge: PR ##{pr_number} already merged on GitHub")

    Result.new(reconciled: true, reason: "auto_merge: PR ##{pr_number} already merged on GitHub")
  rescue Octokit::NotFound, Octokit::Error => e
    Result.new(reconciled: false, reason: "auto_merge: GitHub check failed: #{e.message}")
  end

  def reconcile_external_pr_merge
    pr_number = job.external_pr_number
    return unreconciled unless pr_number.present?

    if job.closed? && job.closure_reason == "external_pr_merged"
      recover_success!("external_pr_merge: external PR ##{pr_number} already closed as merged by Syrus")
      return Result.new(reconciled: true, reason: "external_pr_merge: external PR ##{pr_number} already closed as merged by Syrus")
    end

    client = GithubClient.for(repository: job.repository, user: job.user)
    pr = client.pull_request(job.repository.slug, pr_number, bypass_cache: true)
    return unreconciled unless pr[:merged]

    recover_success!("external_pr_merge: external PR ##{pr_number} already merged on GitHub")

    Result.new(reconciled: true, reason: "external_pr_merge: external PR ##{pr_number} already merged on GitHub")
  rescue Octokit::NotFound, Octokit::Error => e
    Result.new(reconciled: false, reason: "external_pr_merge: GitHub check failed: #{e.message}")
  end

  def reconcile_merge_train_land
    pr_number = workflow.artifact(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT).to_s.presence
    return unreconciled unless pr_number.present?

    client = GithubClient.for(repository: job.repository, user: job.user)
    pr = client.pull_request(job.repository.slug, pr_number.to_i, bypass_cache: true)
    return unreconciled unless pr[:merged]

    recover_success!("merge_train_land: integration PR ##{pr_number} already merged on GitHub")

    Result.new(reconciled: true, reason: "merge_train_land: integration PR ##{pr_number} already merged on GitHub")
  rescue Octokit::NotFound, Octokit::Error => e
    Result.new(reconciled: false, reason: "merge_train_land: GitHub check failed: #{e.message}")
  end

  def unreconciled
    Result.new(reconciled: false, reason: @unreconciled_reason)
  end

  def recover_success!(reason)
    if allow_terminal_recovery
      force_success_after_terminal_race!(reason)
    else
      mark_run_succeeded!
      sync_step_from_run!

      StepDispatcher.advance_from(step.reload) if workflow.reload.running?
      finish_workflow_if_terminal!
    end
  end

  def mark_run_succeeded!
    if run.may_succeed?
      run.succeed!
      run.save!
    elsif run.succeeded?
      true
    else
      raise "Run cannot transition to succeeded from #{run.state}"
    end
  end

  def sync_step_from_run!
    sync = Steps::StateSynchronizer.from_latest_terminal_run!(step, runs: step.runs.to_a)
    raise sync.reason unless sync.synchronized?
  end

  def finish_workflow_if_terminal!
    workflow.reload
    return unless workflow.running?
    return if workflow.live_descendants?
    return unless workflow.may_succeed?

    workflow.succeed!
    workflow.save!
  end

  def force_success_after_terminal_race!(reason)
    now = Time.current
    StateTransition.with_source("reconciler", reason: "post_handler_terminal_success_race", metadata: { reason: reason }) do
      force_state!(run, "succeeded", now)
      force_state!(step, "succeeded", now)
      force_state!(workflow, "succeeded", now)
    end
    Runs::LifecyclePropagation.succeeded!(run.reload)
    Runs::LifecyclePropagation.terminal!(run)
    Workflows::LifecyclePropagation.succeeded!(workflow.reload)
  end

  def force_state!(record, state, now)
    from = record.state
    return if from == state

    record.update_columns(state: state, finished_at: now, updated_at: now)
    StateTransition.create!(
      subject: record,
      from_state: from,
      to_state: state,
      event_name: "reconcile_success",
      source: StateTransition.current_source,
      user_id: StateTransition.current_user&.id,
      run_id: StateTransition.current_run_id,
      metadata: StateTransition.current_reason_metadata.merge("reason_key" => StateTransition.current_reason_key).compact
    )
    record.reload
  end

  attr_reader :allow_terminal_recovery
end
