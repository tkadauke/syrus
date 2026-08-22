require "rails_helper"

RSpec.describe WorkUnits::WorkflowLifecycle do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "marks the attached work unit running when the workflow starts" do
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    unit = workflow.work_unit

    described_class.started!(workflow)

    expect(unit.reload).to have_attributes(state: "running")
    expect(unit.started_at).to be_present
    expect(unit.finished_at).to be_nil
  end

  it "marks the attached work unit terminal when the workflow finishes" do
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    workflow.work_unit.mark_running!

    described_class.terminal!(workflow, state: "failed")

    expect(workflow.work_unit.reload).to have_attributes(state: "failed")
    expect(workflow.work_unit.finished_at).to be_present
  end

  it "ignores legacy workflows without work units" do
    workflow = Workflows::ManualVisualReview.instantiate(job: job)

    expect { described_class.started!(workflow) }.not_to raise_error
    expect { described_class.terminal!(workflow, state: "cancelled") }.not_to raise_error
  end
end
