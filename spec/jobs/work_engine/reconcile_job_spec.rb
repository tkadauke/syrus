require "rails_helper"

RSpec.describe WorkEngine::ReconcileJob do
  def enable_unified_work_engine_reconciler!
    Feature.find_or_initialize_by(slug: "unified_work_engine_reconciler").tap do |feature|
      feature.name = "Unified work-engine reconciler"
      feature.category = "operations"
      feature.enabled = true
      feature.save!
    end
  end

  it "runs the reconciler read-only while the feature gate is off" do
    expect(WorkEngine::Reconciler).to receive(:call).with(
      source: "spec",
      job_id: 1,
      workflow_id: nil,
      run_id: nil,
      execute_repairs: false
    )

    described_class.perform_now(source: "spec", job_id: 1)
  end

  it "executes safe repairs only when the feature gate is on" do
    enable_unified_work_engine_reconciler!

    expect(WorkEngine::Reconciler).to receive(:call).with(
      source: "spec",
      job_id: nil,
      workflow_id: 2,
      run_id: nil,
      execute_repairs: true
    )

    described_class.perform_now(source: "spec", workflow_id: 2)
  end
end
