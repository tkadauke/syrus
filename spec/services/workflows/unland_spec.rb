require "rails_helper"

RSpec.describe Workflows::Unland do
  it "builds, validates, summarizes, and publishes a rollback PR" do
    workflow = described_class.instantiate(job: Factories.job)

    expect(described_class.trigger_kind).to eq("unland")
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[unland_revert unland_conflict prepare grader_fanout grader_collect summarize pr_open]
    )
    expect(Workflow::TriggerKind.template_for("unland")).to eq(described_class)
  end

  it "marks a nonterminal rollback Job failed when the workflow fails" do
    job = Factories.job_record(state: "running")
    workflow = described_class.instantiate(job: job)

    described_class.after_fail(workflow)

    expect(job.reload).to be_failed
  end

  it "marks a nonterminal rollback Job failed when the workflow is canceled" do
    job = Factories.job_record(state: "running")
    workflow = described_class.instantiate(job: job)

    described_class.after_cancel(workflow)

    expect(job.reload).to be_failed
  end
end
