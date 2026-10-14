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
end
