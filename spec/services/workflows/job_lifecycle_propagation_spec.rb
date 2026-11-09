require "rails_helper"

RSpec.describe Workflows::JobLifecyclePropagation do
  Workflow::TriggerKind::NON_APPROVAL_BLOCKING_VALUES.each do |kind|
    it "keeps an implemented Job approvable when a #{kind} workflow starts" do
      job = Factories.job_record(state: "implemented")
      workflow = Workflow.create!(job: job, trigger_kind: kind, state: "running")

      described_class.start!(workflow)

      expect(job.reload).to be_implemented
    end
  end

  it "closes a failed workflow as no_changes when the failed run produced no changes" do
    job = Factories.job
    workflow = job.workflows.last
    run = job.initial_run

    job.update_columns(state: "running")
    workflow.update_columns(state: "failed")
    run.update_columns(state: "failed")
    run.create_run_diagnostic!(
      error_class: "Steps::Base::NoChangesProduced",
      error_message: "agent produced no changes"
    )

    described_class.fail!(workflow.reload)

    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("no_changes")
  end

  it "fails the Job when a retried run fails for a reason other than no changes" do
    job = Factories.job
    workflow = job.workflows.last
    step = workflow.steps.first
    no_changes_run = job.initial_run

    job.update_columns(state: "running")
    workflow.update_columns(state: "failed")
    step.update_columns(state: "failed")
    no_changes_run.update_columns(state: "failed", created_at: 2.minutes.ago)
    no_changes_run.create_run_diagnostic!(
      error_class: "Steps::Base::NoChangesProduced",
      error_message: "agent produced no changes"
    )
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      state: "failed",
      created_at: 1.minute.ago
    ).create_run_diagnostic!(
      error_class: "Steps::Base::StepFailed",
      error_message: "worker died"
    )

    described_class.fail!(workflow.reload)

    expect(job.reload).to be_failed
    expect(job.closure_reason).to be_nil
  end

  it "does not overwrite a Job state owned by later lifecycle phases" do
    job = Factories.job
    workflow = job.workflows.last
    run = job.initial_run

    job.update_columns(state: "implemented")
    workflow.update_columns(state: "failed")
    run.update_columns(state: "failed")
    run.create_run_diagnostic!(
      error_class: "Steps::Base::NoChangesProduced",
      error_message: "agent produced no changes"
    )

    expect { described_class.fail!(workflow.reload) }
      .not_to change { job.reload.attributes.slice("state", "closure_reason") }
  end
end

RSpec.describe Workflows::JobLifecyclePropagation, "ci_failure no-diff follow-up" do
  def failing_ci_workflow(job, head_sha: "abc123")
    workflow = job.workflows.create!(trigger_kind: "ci_failure", state: "failed")
    workflow.set_artifact!("head_sha", head_sha)
    workflow.set_artifact!("failed_checks", [ { "name" => "rspec" } ])
    run = job.initial_run
    run.update_columns(state: "failed")
    allow(workflow).to receive_message_chain(:runs, :where, :reorder, :first).and_return(run)
    run.create_run_diagnostic!(error_class: "Steps::Base::NoChangesProduced", error_message: "none")
    workflow
  end

  it "preserves the PR and returns the Job to implemented instead of closing" do
    job = Factories.job
    job.update_columns(state: "running", pr_number: 42)
    workflow = failing_ci_workflow(job)
    allow(PollPullRequestJob).to receive(:perform_later)

    described_class.fail!(workflow)

    expect(job.reload).to be_implemented
    expect(job.closure_reason).to be_nil
    outcome = workflow.artifact("ci_failure_outcome")
    expect(outcome).to include("outcome" => "inconclusive", "head_sha" => "abc123", "check_names" => [ "rspec" ])
    expect(PollPullRequestJob).to have_received(:perform_later).with(job.id)
  end

  it "keeps an approved Job approved and records passing reproduction evidence" do
    job = Factories.job
    job.update_columns(state: "approved", pr_number: 42, last_ci_handled_sha: "abc123", pr_checks_checked_at: Time.current)
    workflow = failing_ci_workflow(job)
    workflow.steps.create!(
      kind: "grader", state: "succeeded", position: 99,
      details: { "command" => "bin/rspec spec/a_spec.rb", "source_sha" => "abc123", "exit_code" => 0 }
    )
    allow(PollPullRequestJob).to receive(:perform_later)

    described_class.fail!(workflow)

    expect(job.reload).to be_approved
    expect(job.pr_checks_checked_at).to be_nil
    expect(workflow.artifact("ci_failure_outcome")).to include(
      "outcome" => "failure_not_reproduced",
      "reproduction_command" => "bin/rspec spec/a_spec.rb",
      "reproduction_sha" => "abc123"
    )
  end

  it "escalates after repeated non-reproductions on the same SHA without closing" do
    job = Factories.job
    job.update_columns(state: "running", pr_number: 42)
    prior = job.workflows.create!(trigger_kind: "ci_failure", state: "failed")
    prior.set_artifact!("head_sha", "abc123")
    prior.set_artifact!("ci_failure_outcome", { "head_sha" => "abc123" })
    workflow = failing_ci_workflow(job)

    described_class.fail!(workflow)

    expect(job.reload).to be_implemented
    expect(job.landing_failure_reason).to include("ci_failure_not_reproduced")
    expect(workflow.artifact("ci_failure_outcome")["escalated"]).to be(true)
  end
end
