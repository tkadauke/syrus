require "rails_helper"

RSpec.describe WorkflowWorkspacePruneJob do
  # Stub filesystem cleanup so the job exercises its DB query logic
  # without touching disk. The underlying WorkflowWorkspace.cleanup_for
  # is tested separately in the WorkflowWorkspace spec.
  before do
    allow(WorkflowWorkspace).to receive(:cleanup_for) do |wf|
      wf.update_columns(cleaned_up_at: Time.current)
    end
  end

  def make_workflow(state:, finished_at: nil, cleaned_up_at: nil)
    job = Factories.job
    wf  = Workflow.create!(job: job, trigger_kind: "initial")
    wf.update_columns(state: state, finished_at: finished_at, cleaned_up_at: cleaned_up_at)
    wf
  end

  it "cleans up terminal workflows whose finished_at is past the retention window" do
    old = make_workflow(state: "failed", finished_at: (WorkflowWorkspacePruneJob::RETAIN_AFTER_TERMINAL + 1.day).ago)

    expect(WorkflowWorkspace).to receive(:cleanup_for).with(old)
    described_class.perform_now
  end

  it "does not clean up workflows finished inside the retention window" do
    recent = make_workflow(state: "failed", finished_at: 1.hour.ago)

    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(recent)
    described_class.perform_now
  end

  it "skips workflows that are already cleaned up" do
    already_done = make_workflow(
      state: "failed",
      finished_at: (WorkflowWorkspacePruneJob::RETAIN_AFTER_TERMINAL + 1.day).ago,
      cleaned_up_at: 1.day.ago
    )

    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(already_done)
    described_class.perform_now
  end

  it "skips active workflows even if they're old" do
    active = make_workflow(state: "running", finished_at: nil)
    active.update_columns(created_at: 1.year.ago)

    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(active)
    described_class.perform_now
  end

  it "cleans up succeeded and cancelled workflows past retention too" do
    succeeded  = make_workflow(state: "succeeded",  finished_at: (WorkflowWorkspacePruneJob::RETAIN_AFTER_TERMINAL + 1.day).ago)
    cancelled  = make_workflow(state: "cancelled",  finished_at: (WorkflowWorkspacePruneJob::RETAIN_AFTER_TERMINAL + 1.day).ago)

    expect(WorkflowWorkspace).to receive(:cleanup_for).with(succeeded)
    expect(WorkflowWorkspace).to receive(:cleanup_for).with(cancelled)
    described_class.perform_now
  end

  it "is a no-op when nothing is prunable" do
    make_workflow(state: "failed", finished_at: 1.hour.ago)

    expect(WorkflowWorkspace).not_to receive(:cleanup_for)
    described_class.perform_now
  end
end
