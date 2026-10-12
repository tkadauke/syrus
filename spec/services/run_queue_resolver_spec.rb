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

  it "uses the process hostname column when worker metadata omits capability identity" do
    ensure_solid_queue_test_tables!
    instance = InstanceVersion.create!(
      hostname: "mac-worker",
      role: "worker",
      version: "abc123",
      started_at: 1.minute.ago,
      last_heartbeat_at: Time.current,
      capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] }
    )
    SolidQueue::Process.create!(
      hostname: instance.hostname,
      kind: "Worker",
      name: "worker-1",
      pid: 123,
      last_heartbeat_at: Time.current,
      metadata: {
        "queues" => "runs-macos-arm64",
        "polling_interval" => 0.1,
        "pool_size" => 1
      }
    )
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      planned_execution_capabilities: { "os" => [ "macos" ] }
    )
    step = Step.create!(
      workflow: workflow,
      kind: "prepare",
      position: 0,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )
    run = step.runs.create!(job: job, trigger_kind: "initial", agent_provider: workflow.agent_provider)

    decision = described_class.resolve(run: run)

    expect(decision.queue_name).to eq("runs-macos-arm64")
    expect(decision).not_to be_blocked
  end
end
