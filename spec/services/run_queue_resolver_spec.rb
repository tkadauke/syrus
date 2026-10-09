require "rails_helper"

RSpec.describe RunQueueResolver, :ci_only do
  let(:job) { Factories.job }

  def mutable_run_with_storage(storage_key)
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      worker_storage_key: storage_key
    )
    step = Step.create!(
      workflow: workflow,
      kind: "summarize",
      position: 1,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )

    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
  end

  it "preserves a live storage-affinity queue for default mutable retries when no capability payload is available" do
    run = mutable_run_with_storage("storage-main")
    queue = "resume-storage-main"
    allow(InstanceVersion).to receive(:worker_queue_live?).with(queue).and_return(true)

    decision = described_class.resolve(run: run)

    expect(decision.queue_name).to eq(queue)
    expect(decision.sticky_resume).to eq(true)
    expect(decision).not_to be_blocked
  end
end
