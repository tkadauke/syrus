require "rails_helper"

RSpec.describe Workflows::JobLifecyclePropagation do
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
