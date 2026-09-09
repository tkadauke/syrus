require "rails_helper"

RSpec.describe RunJobConcurrencyKey do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) do
    Workflow.create!(
      job: job,
      user: user,
      trigger_kind: "initial",
      agent_provider: job.agent_provider
    )
  end

  it "keeps pinned workflow workspace Steps on the per-Job concurrency key" do
    first_run = create_run("implement", placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE)
    second_run = create_run("summarize", placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE)

    expect(described_class.for(first_run.id)).to eq("job:#{job.id}")
    expect(described_class.for(second_run.id)).to eq("job:#{job.id}")
  end

  it "keeps immutable-source Steps on the per-Job key until worker-slot admission is enabled" do
    enable_distributed_workflow_dag!
    first_run = create_run("grader", placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)
    second_run = create_run("grader", placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)

    expect(described_class.for(first_run.id)).to eq("job:#{job.id}")
    expect(described_class.for(second_run.id)).to eq("job:#{job.id}")
  end

  it "lets immutable-source Steps use separate keys while worker-slot placement rejects same-worker overlap" do
    enable_distributed_workflow_dag!
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
    allow(InstanceVersion).to receive(:worker_queue_live?).and_return(true)

    first_run = create_run("grader", placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)
    second_run = create_run("grader", placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)

    expect(described_class.for(first_run.id)).to eq("job:#{job.id}:immutable_source_step:#{first_run.step_id}")
    expect(described_class.for(second_run.id)).to eq("job:#{job.id}:immutable_source_step:#{second_run.step_id}")

    allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-a")
    expect(WorkflowStepWorkerSlot.acquire_for(first_run)).to be_acquired
    expect(WorkflowStepWorkerSlot.acquire_for(second_run)).to be_deferred

    allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-b")
    expect(WorkflowStepWorkerSlot.acquire_for(second_run)).to be_acquired
    expect(WorkflowStepWorkerSlot.active.pluck(:worker_storage_key)).to contain_exactly("storage-a", "storage-b")
  end

  def enable_distributed_workflow_dag!
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    repository.update!(distributed_workflow_dag_enabled: true)
  end

  def create_run(kind, placement_policy:)
    step = Step.create!(
      workflow: workflow,
      kind: kind,
      position: workflow.steps.count,
      placement_policy: placement_policy
    )
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
  end
end
