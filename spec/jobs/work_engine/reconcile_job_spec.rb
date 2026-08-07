require "rails_helper"

RSpec.describe WorkEngine::ReconcileJob do
  it "always executes safe repairs" do
    expect(WorkEngine::Reconciler).to receive(:call).with(
      source: "spec",
      job_id: nil,
      workflow_id: 2,
      run_id: nil,
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
end
