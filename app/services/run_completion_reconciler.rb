class RunCompletionReconciler
  Result = Data.define(:reconciled, :reason) do
    def reconciled? = reconciled
  end

  PR_OPENED_PATTERN = /pr_open: opened PR #(?<number>\d+)/.freeze
  EXISTING_PR_PUSHED_PATTERN = /pr_open: branch pushed for existing PR #(?<number>\d+)/.freeze

  def self.call(...) = new(...).call

  def initialize(run)
    @run = run
    @step = run.step
    @workflow = @step&.workflow
    @job = run.job
  end

  def call
    return unreconciled unless run&.running?
    return unreconciled unless step&.running?
    return unreconciled unless workflow&.running?

    strategy = Step::Kind.fetch(step.kind).reconcile_strategy
    return unreconciled unless strategy

    send(:"reconcile_#{strategy}")
  rescue ArgumentError
    unreconciled
  end

  private

  attr_reader :run, :step, :workflow, :job

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

    run.succeed!
    run.save!
    step.succeed!
    step.save!

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

    client = GithubClient.for(repository: job.repository, user: job.user)
    pr = client.pull_request(job.repository.slug, pr_number, bypass_cache: true)
    return unreconciled unless pr[:merged]

    run.succeed!
    run.save!
    step.succeed!
    step.save!

    StepDispatcher.advance_from(step.reload) if workflow.reload.running?
    finish_workflow_if_terminal!

    Result.new(reconciled: true, reason: "auto_merge: PR ##{pr_number} already merged on GitHub")
  rescue Octokit::NotFound, Octokit::Error => e
    Result.new(reconciled: false, reason: "auto_merge: GitHub check failed: #{e.message}")
  end

  def reconcile_merge_train_land
    pr_number = workflow.artifact(Steps::MergeTrainLand::INTEGRATION_PR_ARTIFACT).to_s.presence
    return unreconciled unless pr_number.present?

    client = GithubClient.for(repository: job.repository, user: job.user)
    pr = client.pull_request(job.repository.slug, pr_number.to_i, bypass_cache: true)
    return unreconciled unless pr[:merged]

    run.succeed!
    run.save!
    step.succeed!
    step.save!

    StepDispatcher.advance_from(step.reload) if workflow.reload.running?
    finish_workflow_if_terminal!

    Result.new(reconciled: true, reason: "merge_train_land: integration PR ##{pr_number} already merged on GitHub")
  rescue Octokit::NotFound, Octokit::Error => e
    Result.new(reconciled: false, reason: "merge_train_land: GitHub check failed: #{e.message}")
  end

  def unreconciled
    Result.new(reconciled: false, reason: nil)
  end

  def finish_workflow_if_terminal!
    workflow.reload
    return unless workflow.running?
    return if workflow.live_descendants?
    return unless workflow.may_succeed?

    workflow.succeed!
    workflow.save!
  end
end
