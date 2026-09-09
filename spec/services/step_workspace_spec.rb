require "rails_helper"

RSpec.describe StepWorkspace, :ci_only do
  let(:repository) { Factories.repository(distributed_workflow_dag_enabled: true) }
  let(:job) { Factories.job_record(repository: repository, state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }

  it "uses the legacy workflow workspace while the distributed gate is off" do
    step = Step.create!(workflow: workflow, kind: "grader", position: 0)

    expect(described_class.for(step)).to be_a(WorkflowWorkspace)
  end

  it "uses immutable source checkouts for immutable Steps when both gates are enabled" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 0,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT
    )

    expect(described_class.for(step)).to be_a(ImmutableSourceCheckout)
  end

  it "keeps pinned Steps on the legacy mutable workflow workspace" do
    Feature.create!(slug: "distributed_workflow_dag", category: "Operations", name: "Distributed workflow DAG", enabled: true)
    step = Step.create!(
      workflow: workflow,
      kind: "implement",
      position: 0,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )

    expect(described_class.for(step)).to be_a(WorkflowWorkspace)
  end
end
