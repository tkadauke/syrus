require "rails_helper"

RSpec.describe RetryWorkflowEnqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, agent_provider: "claude") }

  def finish_current_run!(state: "succeeded")
    run = job.current_run
    run.start! if run.may_start?
    state == "succeeded" ? run.succeed! : run.fail!
    run.save!
    run.workflow&.work_unit&.mark_terminal!(state)
  end

  def github_issue_with_labels(*names)
    labels = names.map { |name| Struct.new(:name, keyword_init: true).new(name: name) }
    Struct.new(:labels, keyword_init: true).new(labels: labels)
  end

  def record_provider_transient_failure!(provider: "claude", issue_number:)
    failed_job = Factories.job(repository: repository, issue_number: issue_number, agent_provider: provider)
    Run.create!(
      job: failed_job,
      step: failed_job.latest_workflow.first_step,
      trigger_kind: "initial",
      state: "failed",
      agent_provider: provider,
      agent_outcome: "provider_transient",
      finished_at: 1.minute.ago
    )
  end

  it "creates and starts a retry workflow" do
    finish_current_run!

    expect(WorkUnits::Launcher).to receive(:start!).once.and_call_original
    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
      expect(result.workflow.trigger_kind).to eq("retry")
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(workflow.first_step.runs.last.agent_provider).to eq("claude")
  end

  # Regression: an agent-blocked Workflow kept its WorkUnit (and job lock)
  # active, so every retry -- the reconciler's and the operator's -- was
  # refused as "already queued or running" and the Job stayed blocked.
  it "retries a Job whose implementation Workflow an agent blocked" do
    blocked = job.latest_workflow
    run = job.current_run
    run.start! if run.may_start?
    run.update_columns(state: "blocked", finished_at: Time.current)
    blocked.first_step.update_columns(state: "blocked", finished_at: Time.current)
    blocked.update_columns(state: "blocked", finished_at: Time.current)
    blocked.set_artifact!("cannot_proceed", { "reason" => "Prerequisite not met" })
    blocked.work_unit.update_columns(state: "blocked")

    result = described_class.call(job: job, provider_validation: :none, automatic: true)

    expect(result).to be_success
    expect(result.workflow).not_to eq(blocked)
    expect(blocked.reload).to be_blocked
    expect(blocked.work_unit.reload.state).to eq("cancelled")
    expect(blocked.work_unit.work_unit_locks.active).to be_empty
  end

  it "does not carry branch-divergence artifacts into retry workflows" do
    finish_current_run!

    result = described_class.call(
      job: job,
      artifacts: {
        "branch_divergence" => { "remote_sha" => "remote-sha", "local_sha" => "local-sha" },
        "branch_divergence_recovery" => { "action" => "discarded" },
        "branch_divergence_recovery_error" => { "message" => "stale" },
        "branch_divergence_recovery_pending" => { "action" => "force_push" },
        "auto_retry_attempt_id" => 123
      }
    )

    expect(result).to be_success
    expect(result.workflow.artifact("auto_retry_attempt_id")).to eq(123)
    expect(result.workflow.artifact("branch_divergence")).to be_nil
    expect(result.workflow.artifact("branch_divergence_recovery")).to be_nil
    expect(result.workflow.artifact("branch_divergence_recovery_error")).to be_nil
    expect(result.workflow.artifact("branch_divergence_recovery_pending")).to be_nil
  end

  it "resumes from a durable checkpoint when a downstream failed workflow has not been cleaned up yet" do
    failed_job = Factories.job_record(user: user, repository: repository, state: "failed", agent_provider: "claude")
    failed_workflow = Workflow.create!(
      job: failed_job,
      user: user,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "failed",
      artifacts: {
        "pr_title" => "Existing title",
        "branch_divergence" => { "remote_sha" => "remote-sha", "local_sha" => "local-sha" },
        "branch_divergence_recovery" => { "action" => "discarded" },
        "branch_divergence_recovery_error" => { "message" => "stale" },
        "branch_divergence_recovery_pending" => { "action" => "force_push" }
      }
    )
    implement = Step.create!(workflow: failed_workflow, kind: "implement", position: 1, state: "succeeded", finished_at: 2.minutes.ago)
    summarize = Step.create!(workflow: failed_workflow, kind: "summarize", position: 2, state: "failed", finished_at: 1.minute.ago)
    implement.update!(next_step: summarize)
    implement_run = implement.runs.create!(
      job: failed_job,
      user: user,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "succeeded",
      head_sha: "implsha",
      base_sha: "basesha",
      finished_at: 2.minutes.ago
    )
    RunCheckpoint.create!(
      run: implement_run,
      workflow: failed_workflow,
      step: implement,
      job: failed_job,
      repository: repository,
      user: user,
      step_kind: "implement",
      commit_sha: "implsha",
      base_sha: "basesha",
      remote_ref: "refs/syrus/checkpoints/runs/#{implement_run.id}",
      status: "published",
      published_at: 2.minutes.ago
    )

    result = described_class.call(job: failed_job)

    expect(result).to be_success
    expect(result.workflow.artifact("checkpoint_ref")).to eq("refs/syrus/checkpoints/runs/#{implement_run.id}")
    expect(result.workflow.artifact("checkpoint_sha")).to eq("implsha")
    expect(result.workflow.artifact("branch_divergence")).to be_nil
    expect(result.workflow.artifact("branch_divergence_recovery")).to be_nil
    expect(result.workflow.artifact("branch_divergence_recovery_error")).to be_nil
    expect(result.workflow.artifact("branch_divergence_recovery_pending")).to be_nil
    expect(result.workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare summarize])
    expect(result.workflow.first_step.runs.last.agent_provider).to eq("claude")
  end

  # Regression: a checkpoint-resume attempt restores the checkpoint it resumed
  # from but never publishes one of its own. When it failed again (pr_open's
  # stack rebase), the next automatic retry found no checkpoint in it and
  # started a fresh implementation, discarding the completed work and the
  # operator guidance it carried.
  it "resumes a failed checkpoint-resume attempt from the checkpoint it inherited" do
    failed_job = Factories.job_record(user: user, repository: repository, state: "failed", agent_provider: "claude")
    original = Workflow.create!(job: failed_job, user: user, trigger_kind: "initial", agent_provider: "claude",
                                state: "failed", created_at: 1.hour.ago)
    implement = Step.create!(workflow: original, kind: "implement", position: 1, state: "succeeded", finished_at: 1.hour.ago)
    original_pr_open = Step.create!(workflow: original, kind: "pr_open", position: 2, state: "failed", finished_at: 1.hour.ago)
    implement.update!(next_step: original_pr_open)
    implement_run = implement.runs.create!(job: failed_job, user: user, trigger_kind: "initial", agent_provider: "claude",
                                           state: "succeeded", head_sha: "implsha", base_sha: "basesha", finished_at: 1.hour.ago)
    RunCheckpoint.create!(run: implement_run, workflow: original, step: implement, job: failed_job, repository: repository,
                          user: user, step_kind: "implement", commit_sha: "implsha", base_sha: "basesha",
                          remote_ref: "refs/syrus/checkpoints/runs/#{implement_run.id}", status: "published",
                          published_at: 1.hour.ago)
    resumed = Workflow.create!(
      job: failed_job, user: user, trigger_kind: "retry", agent_provider: "claude", state: "failed",
      created_at: 10.minutes.ago, finished_at: 5.minutes.ago,
      artifacts: {
        "checkpoint_resume" => true,
        "checkpoint_ref" => "refs/syrus/checkpoints/runs/#{implement_run.id}",
        "checkpoint_sha" => "implsha",
        "checkpoint_source_run_id" => implement_run.id,
        "checkpoint_source_workflow_id" => original.id,
        "replay_context" => "Operator guidance: keep the host surface baseline at 479."
      }
    )
    prepare = Step.create!(workflow: resumed, kind: "prepare", position: 0, state: "succeeded", finished_at: 8.minutes.ago)
    pr_open = Step.create!(workflow: resumed, kind: "pr_open", position: 1, state: "failed", finished_at: 5.minutes.ago)
    prepare.update!(next_step: pr_open)

    result = described_class.call(job: failed_job)

    expect(result).to be_success
    expect(result.workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare pr_open])
    expect(result.workflow.artifact("checkpoint_sha")).to eq("implsha")
    expect(result.workflow.artifact("checkpoint_source_workflow_id")).to eq(resumed.id)
    expect(result.workflow.artifact("replay_context")).to eq("Operator guidance: keep the host surface baseline at 479.")
  end

  # Regression (formal/SyrusModel/CheckpointLineage.lean): a retry resumes
  # the attempt it retries -- the Job's newest. It used to pick the newest
  # failed workflow that *had* a resumable checkpoint, so after a newer
  # attempt (a feedback workflow that pushed, or a later failure elsewhere)
  # the retry restored and pushed an older checkpoint's code.
  {
    "a newer workflow succeeded" => %w[chat_feedback succeeded],
    "a newer workflow failed somewhere unresumable" => %w[retry failed]
  }.each do |description, (kind, state)|
    it "does not resume an older attempt's checkpoint when #{description}" do
      failed_job = Factories.job_record(user: user, repository: repository, state: "failed", agent_provider: "claude")
      older = Workflow.create!(job: failed_job, user: user, trigger_kind: "initial", agent_provider: "claude",
                               state: "failed", created_at: 2.hours.ago)
      implement = Step.create!(workflow: older, kind: "implement", position: 1, state: "succeeded", finished_at: 2.hours.ago)
      summarize = Step.create!(workflow: older, kind: "summarize", position: 2, state: "failed", finished_at: 2.hours.ago)
      implement.update!(next_step: summarize)
      implement_run = implement.runs.create!(job: failed_job, user: user, trigger_kind: "initial", agent_provider: "claude",
                                             state: "succeeded", head_sha: "oldsha", base_sha: "basesha", finished_at: 2.hours.ago)
      RunCheckpoint.create!(run: implement_run, workflow: older, step: implement, job: failed_job, repository: repository,
                            user: user, step_kind: "implement", commit_sha: "oldsha", base_sha: "basesha",
                            remote_ref: "refs/syrus/checkpoints/runs/#{implement_run.id}", status: "published",
                            published_at: 2.hours.ago)
      newer = Workflow.create!(job: failed_job, user: user, trigger_kind: kind, agent_provider: "claude", state: state,
                               created_at: 1.hour.ago, finished_at: 1.hour.ago)
      Step.create!(workflow: newer, kind: "implement", position: 1, state: state, finished_at: 1.hour.ago)

      expect(RunCheckpointResume.call(job: failed_job)).not_to be_success
    end
  end

  it "gracefully reports a conflict instead of raising when a checkpoint resume races an active WorkUnit" do
    # RunCheckpointResume's own WorkUnits::Launcher.instantiate
    # call (kind: "checkpoint_resume") must be rescued the same way as
    # the plain "retry" path above.
    failed_job = Factories.job_record(user: user, repository: repository, state: "failed", agent_provider: "claude")
    failed_workflow = Workflow.create!(
      job: failed_job,
      user: user,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "failed",
      artifacts: { "pr_title" => "Existing title" }
    )
    implement = Step.create!(workflow: failed_workflow, kind: "implement", position: 1, state: "succeeded", finished_at: 2.minutes.ago)
    summarize = Step.create!(workflow: failed_workflow, kind: "summarize", position: 2, state: "failed", finished_at: 1.minute.ago)
    implement.update!(next_step: summarize)
    implement_run = implement.runs.create!(
      job: failed_job,
      user: user,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "succeeded",
      head_sha: "implsha2",
      base_sha: "basesha2",
      finished_at: 2.minutes.ago
    )
    RunCheckpoint.create!(
      run: implement_run,
      workflow: failed_workflow,
      step: implement,
      job: failed_job,
      repository: repository,
      user: user,
      step_kind: "implement",
      commit_sha: "implsha2",
      base_sha: "basesha2",
      remote_ref: "refs/syrus/checkpoints/runs/#{implement_run.id}",
      status: "published",
      published_at: 2.minutes.ago
    )
    WorkUnits::Launcher.instantiate(kind: "chat_feedback", job: failed_job)

    expect {
      result = described_class.call(job: failed_job)
      expect(result).not_to be_success
      expect(result.error).to include("already queued or running")
    }.not_to change { failed_job.workflows.where(trigger_kind: "retry").count }
  end

  it "uses an explicit provider only for the new retry workflow" do
    finish_current_run!
    user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test")

    result = described_class.call(job: job, agent_provider: "codex")

    expect(result).to be_success
    expect(job.reload.agent_provider).to eq("claude")
    expect(job.job_provider_setting).to eq("default")
    expect(result.workflow.agent_provider).to eq("codex")
    expect(result.workflow.first_step.runs.last.agent_provider).to eq("codex")
  end

  it "uses the job provider setting for future retry workflows" do
    finish_current_run!
    user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test")
    job.update!(agent_provider: "claude", job_provider_setting: "codex")

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(job.reload.agent_provider).to eq("claude")
    expect(result.workflow.agent_provider).to eq("codex")
    expect(result.workflow.first_step.runs.last.agent_provider).to eq("codex")
  end

  it "resolves default jobs from the current repository default for new workflows" do
    finish_current_run!
    user.update!(agent_provider: "codex", codex_auth_mode: "api_key", codex_api_key: "sk-test")
    job.update!(agent_provider: "claude", job_provider_setting: "default")

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(result.workflow.agent_provider).to eq("codex")
    expect(job.reload.agent_provider).to eq("claude")
  end

  it "rejects closed jobs" do
    finish_current_run!
    job.close_with_reason!("manual")

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("Thread is closed - reopen it to continue.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "rejects jobs with an active run" do
    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("A Run is already in progress - wait for it to finish.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "rejects jobs with an active retry workflow that has not started a run yet" do
    finish_current_run!
    WorkUnits::Launcher.instantiate(kind: "retry", job: job, idempotency_key: "active-retry")

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("A retry workflow is already queued or running for this Job.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "gracefully reports a conflict instead of raising when a non-retry active WorkUnit races the same job lock" do
    # RetryWorkflowEligibility#duplicate_active_retry_workflow?
    # only flags active "retry"/"checkpoint_resume" siblings, so an
    # active chat_feedback WorkUnit (sharing the same "job:<id>" lock)
    # slips past that pre-check. WorkUnits::Launcher must still refuse
    # to materialize a second Workflow, and RetryWorkflowEnqueuer must
    # surface that as a failure Result rather than an unhandled raise.
    finish_current_run!
    WorkUnits::Launcher.instantiate(kind: "chat_feedback", job: job)

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to include("already queued or running")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "does not enqueue implementation retry when the PR is already current and passing" do
    finish_current_run!(state: "failed")
    job.update!(
      state: "failed",
      pr_number: 77,
      branch_name: "syrus/direct-#{job.id}",
      commits_behind_base: 0,
      pr_checks_state: "passing"
    )

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("PR is already current and checks are passing.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }

    expect(job.reload).to be_implemented
  end

  it "rejects retries before the initial workflow has run" do
    job.initial_run.destroy!

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("The initial workflow has not run yet - start or wait for it before retrying.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "rejects approved jobs" do
    finish_current_run!
    job.update!(state: "implemented")
    job.approve!(via: "operator", by_user: user)
    job.save!

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("Job is already approved for landing - unapprove it before retrying.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "rejects landing failures that need landing retry or reapproval" do
    finish_current_run!
    job.update!(state: "implemented", landing_failure_reason: "auto_merge: required grader failed")

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("Landing failed - reapprove the Job or retry the failed landing workflow instead of retrying implementation.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "cancels queued retry workflows when the job is approved" do
    finish_current_run!
    retry_workflow = WorkUnits::Launcher.instantiate(kind: "retry", job: job, idempotency_key: "approval-cancel-retry")
    job.update!(state: "implemented")

    expect {
      job.approve!(via: "operator", by_user: user)
      job.save!
    }.to change { retry_workflow.reload.state }.from("queued").to("cancelled")

    expect(retry_workflow.artifact("retry_cancelled_reason")).to eq("job_approved")
  end

  it "ignores unowned queued retry workflow rows when the job is approved" do
    finish_current_run!
    retry_workflow = Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)
    job.update!(state: "implemented")

    expect {
      job.approve!(via: "operator", by_user: user)
      job.save!
    }.not_to change { retry_workflow.reload.state }
  end

  it "marks the queued retry WorkUnit as preempted when approval cancels it" do
    finish_current_run!
    retry_workflow = WorkUnits::Launcher.instantiate(kind: "retry", job: job, idempotency_key: "approval-cancelled-retry")
    job.update!(state: "implemented")

    job.approve!(via: "operator", by_user: user)
    job.save!

    expect(retry_workflow.reload).to be_cancelled
    expect(retry_workflow.work_unit.reload).to have_attributes(
      state: "cancelled",
      preemption_reason: "job_approved"
    )
  end

  it "syncs skip-prepare from the source issue before instantiating the workflow" do
    finish_current_run!
    user.update!(github_token: "ghp_test_token")
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:fetch_issue)
      .with(repository.slug, job.issue_number)
      .and_return(github_issue_with_labels("syrus", Workflows::SKIP_PREPARE_LABEL))
    stub_repository_content(repository, files: { ".syrus.yml" => "visual_review:\n  enabled: false\n" })

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(job.reload).to be_skip_prepare
    expect(result.workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement dependency_audit summarize test_plan pr_open ])
  end

  it "transitions a :failed Job back to :queued before instantiating the new workflow" do
    # Simulates the realistic post-failure state: the prior run
    # finished, the workflow failed, and Workflow#fail's
    # propagate_fail_to_job! drove the Job to :failed.
    finish_current_run!(state: "failed")
    job.update!(state: "failed")

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
    }.to change { job.reload.state }.from("failed").to("queued")
  end

  it "transitions a stale :running Job back to :queued before instantiating the new workflow" do
    finish_current_run!(state: "failed")
    job.latest_workflow.update!(state: "cancelled", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    job.update!(state: "running")

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
      expect(result.workflow.trigger_kind).to eq("retry")
      expect(result.workflow.state).to eq("queued")
    }.to change { job.reload.state }.from("running").to("queued")
      .and change { job.workflows.where(trigger_kind: "retry").count }.by(1)
  end

  it "keeps Job and latest workflow state aligned after cancel then retry" do
    workflow = job.latest_workflow
    workflow.start!
    workflow.save!

    expect {
      workflow.cancel!
      workflow.save!
    }.to change { job.reload.state }.from("running").to("failed")

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(job.reload.state).to eq("queued")
    expect(job.latest_workflow_state).to eq("queued")
    expect(result.workflow.reload.state).to eq("queued")
  end

  it "transitions a reopened cancelled Job back to :queued before instantiating the new workflow" do
    finish_current_run!(state: "failed")
    initial_workflow = job.latest_workflow
    initial_workflow.update!(state: "cancelled", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    job.update!(state: "closed", closure_reason: "cancelled", finished_at: Time.current)
    job.reopen!
    job.save!
    initial_workflow_count = job.workflows.where(trigger_kind: "initial").count

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
      expect(result.workflow.trigger_kind).to eq("retry")
    }.to change { job.reload.state }.from("triaging").to("queued")
      .and change { job.workflows.where(trigger_kind: "retry").count }.by(1)
    expect(job.workflows.where(trigger_kind: "initial").count).to eq(initial_workflow_count)
  end

  it "is a no-op on Job state when the Job is not :failed (e.g. :implemented retry)" do
    finish_current_run!
    job.update!(state: "implemented")

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
    }.not_to change { job.reload.state }
  end

  it "can enforce alternate retry provider semantics for per-job retries" do
    finish_current_run!
    job.current_run.update!(agent_provider: "claude")
    job.latest_workflow.update!(state: "succeeded")
    user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")

    result = described_class.call(job: job, agent_provider: "claude", provider_validation: :retry_alternate)

    expect(result).not_to be_success
    expect(result.error).to eq("That agent is not available for retry.")
  end

  it "suppresses automatic retries while the provider circuit is open" do
    finish_current_run!(state: "failed")
    decision = ProviderCircuitBreaker::Decision.new(
      provider: job.workflow_agent_provider,
      open: true,
      reason: "provider transient failures",
      retry_after: 10.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: "timeout"
    )
    allow(ProviderCircuitBreaker).to receive(:call)
      .with(
        job.workflow_agent_provider,
        include_logs: false,
        user: job.user,
        provider_account: job.latest_workflow.provider_account
      )
      .and_return(decision)

    expect {
      result = described_class.call(job: job, automatic: true)
      expect(result).not_to be_success
      expect(result.circuit).to be_open
      expect(result.error).to include("Claude Code appears degraded")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "creates a retry workflow for admission failover when an automatic retry provider circuit is open" do
    finish_current_run!(state: "failed")
    decision = ProviderCircuitBreaker::Decision.new(
      provider: job.workflow_agent_provider,
      open: true,
      reason: "provider transient failures",
      retry_after: 10.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: "timeout"
    )
    allow(ProviderCircuitBreaker).to receive(:call)
      .with(
        job.workflow_agent_provider,
        include_logs: false,
        user: job.user,
        provider_account: job.latest_workflow.provider_account
      )
      .and_return(decision)
    allow(ProviderCircuitBreaker).to receive(:call)
      .with(anything, include_logs: false, now: anything)
      .and_return(ProviderCircuitBreaker::Decision.new(
        provider: "codex",
        open: false,
        reason: nil,
        retry_after: nil,
        failure_count: 0,
        job_count: 0,
        signature: nil
      ))
    ProviderRoutingRule.create!(
      scope_type: "user",
      scope_id: user.id,
      task_key: "retry",
      candidates: [ { "provider" => "claude" }, { "provider" => "codex" } ]
    )
    allow(WorkUnits::Launcher).to receive(:start!)

    expect {
      result = described_class.call(job: job, automatic: true)
      expect(result).to be_success
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)

    expect(WorkUnits::Launcher).to have_received(:start!).with(job.workflows.where(trigger_kind: "retry").last)
  end

  context "runaway protection" do
    before do
      finish_current_run!(state: "failed")
      job.update!(state: "failed", runaway_protection: "too_many_workflows", runaway_protection_at: Time.current)
    end

    it "blocks automatic retries when runaway_protection is set" do
      expect {
        result = described_class.call(job: job, automatic: true)
        expect(result).not_to be_success
        expect(result.error).to include("Runaway protection active")
      }.not_to change { job.workflows.where(trigger_kind: "retry").count }

      expect(job.reload.runaway_protection).to eq("too_many_workflows")
    end

    it "allows and clears runaway_protection on a manual (non-automatic) retry" do
      old_reopened_at = job.reopened_at

      expect {
        result = described_class.call(job: job, automatic: false)
        expect(result).to be_success
        expect(result.workflow.trigger_kind).to eq("retry")
      }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)

      job.reload
      expect(job.runaway_protection).to be_nil
      expect(job.runaway_protection_at).to be_nil
      expect(job.reopened_at).to be > (old_reopened_at || 1.year.ago)
    end
  end

  describe "which kind a retry re-runs" do
    # A rebase whose force_push failed used to be "retried" by re-running the
    # entire initial chain -- prepare, implement, both reviews, every grader,
    # pr_open -- discarding a finished, PR-opened implementation to recover
    # from a failed push. A production Job did exactly that.
    def add_failed_workflow!(trigger_kind)
      Workflow.create!(
        job: job, user: job.user, trigger_kind: trigger_kind,
        state: "failed", finished_at: Time.current
      )
    end

    before do
      finish_current_run!
      allow(WorkUnits::Launcher).to receive(:start!)
    end

    it "re-runs a failed rebase as a rebase, not as a full re-implementation" do
      add_failed_workflow!("rebase")

      expect(WorkUnits::Launcher).to receive(:instantiate)
        .with(hash_including(kind: "rebase")).and_call_original

      described_class.call(job: job)
    end

    it "re-runs a failed stack_rebase as a stack_rebase" do
      add_failed_workflow!("stack_rebase")

      expect(WorkUnits::Launcher).to receive(:instantiate)
        .with(hash_including(kind: "stack_rebase")).and_call_original

      described_class.call(job: job)
    end

    it "re-runs a failed main_branch_repair as a main_branch_repair" do
      add_failed_workflow!("main_branch_repair")

      expect(WorkUnits::Launcher).to receive(:instantiate)
        .with(hash_including(kind: "main_branch_repair")).and_call_original

      described_class.call(job: job)
    end

    # Regression: a real main-branch repair Job opens with its main_branch_repair
    # workflow and has no initial one, so its automatic retry was refused as
    # "initial_not_run" and rescheduled hourly while main stayed broken.
    it "automatically retries a main-branch repair Job that never had an initial workflow" do
      repair_job = Factories.job_record(user: job.user, repository: job.repository, state: "failed", issue_title: "Fix broken main branch")
      Workflow.create!(job: repair_job, user: repair_job.user, trigger_kind: "main_branch_repair",
        state: "failed", started_at: 2.hours.ago, finished_at: 1.hour.ago)

      expect(WorkUnits::Launcher).to receive(:instantiate)
        .with(hash_including(kind: "main_branch_repair")).and_call_original

      result = described_class.call(job: repair_job, automatic: true, provider_validation: :none)

      expect(result.error).not_to include("initial workflow has not run") if result.error
    end

    # auto_merge and merge_train own job lifecycle and have their own retry
    # paths, so they must still fall through to the initial-chain retry.
    it "still uses the initial-chain retry for a failed auto_merge" do
      add_failed_workflow!("auto_merge")

      expect(WorkUnits::Launcher).to receive(:instantiate)
        .with(hash_including(kind: "retry")).and_call_original

      described_class.call(job: job)
    end
  end
end
