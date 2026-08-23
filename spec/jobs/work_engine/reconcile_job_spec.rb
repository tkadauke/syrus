require "rails_helper"

RSpec.describe WorkEngine::ReconcileJob do
  it "always executes safe repairs" do
    expect(WorkEngine::Reconciler).to receive(:call).with(
      source: "spec",
      job_id: nil,
      workflow_id: 2,
      run_id: nil,
      work_intent_id: nil,
      execute_repairs: true
    )

    described_class.perform_now(source: "spec", workflow_id: 2)
  end

  it "writes Admin::StuckItemsCache for global reconciler runs" do
    result = instance_double(WorkEngine::Reconciler::Result)
    allow(WorkEngine::Reconciler).to receive(:call).and_return(result)
    expect(Admin::StuckItemsCache).to receive(:write_from_result).with(result: result)

    described_class.perform_now(source: "spec")
  end

  it "does not write Admin::StuckItemsCache for scoped reconciler runs" do
    allow(WorkEngine::Reconciler).to receive(:call).and_return(instance_double(WorkEngine::Reconciler::Result))
    expect(Admin::StuckItemsCache).not_to receive(:write_from_result)

    described_class.perform_now(source: "spec", job_id: 1)
  end

  it "scopes repairs by WorkIntent without refreshing global stuck cache" do
    result = instance_double(WorkEngine::Reconciler::Result)
    expect(WorkEngine::Reconciler).to receive(:call).with(
      source: "spec",
      job_id: nil,
      workflow_id: nil,
      run_id: nil,
      work_intent_id: 42,
      execute_repairs: true
    ).and_return(result)
    expect(Admin::StuckItemsCache).not_to receive(:write_from_result)

    described_class.perform_now(source: "spec", work_intent_id: 42)
  end

  it "keeps legacy Reconciler.request payloads unchanged unless an intent is scoped" do
    job = Factories.job_record
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )

    expect {
      WorkEngine::Reconciler.request(source: "spec", job: job)
    }.to have_enqueued_job(described_class).with(
      source: "spec",
      job_id: job.id,
      workflow_id: nil,
      run_id: nil
    )

    expect {
      WorkEngine::Reconciler.request(source: "spec", work_intent: intent)
    }.to have_enqueued_job(described_class).with(
      source: "spec",
      job_id: nil,
      workflow_id: nil,
      run_id: nil,
      work_intent_id: intent.id
    )
  end
end
