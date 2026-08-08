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

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
      expect(result.workflow.trigger_kind).to eq("retry")
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(workflow.first_step.runs.last.agent_provider).to eq("claude")
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
      expect(result.error).to eq("Thread is closed - use Start over to begin a new one.")
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
    Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("A retry workflow is already queued or running for this Job.")
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
    retry_workflow = Workflows::Retry.instantiate(job: job, agent_provider: job.agent_provider)
    job.update!(state: "implemented")

    expect {
      job.approve!(via: "operator", by_user: user)
      job.save!
    }.to change { retry_workflow.reload.state }.from("queued").to("cancelled")

    expect(retry_workflow.artifact("retry_cancelled_reason")).to eq("job_approved")
  end

  it "syncs skip-prepare from the source issue before instantiating the workflow" do
    finish_current_run!
    user.update!(github_token: "ghp_test_token")
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:fetch_issue)
      .with(repository.slug, job.issue_number)
      .and_return(github_issue_with_labels("syrus", Workflows::SKIP_PREPARE_LABEL))

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(job.reload).to be_skip_prepare
    expect(result.workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ])
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
    5.times { |index| record_provider_transient_failure!(issue_number: index + 100) }

    expect {
      result = described_class.call(job: job, automatic: true)
      expect(result).not_to be_success
      expect(result.circuit).to be_open
      expect(result.error).to include("Claude Code appears degraded")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
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
end
