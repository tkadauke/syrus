require "rails_helper"

# With the plugin's providers absent, core has no gate, no alerts, and no
# classifier: it runs without main-branch gating and raises nothing.
RSpec.describe "main_branch_health providers absent" do
  let(:snapshot) { Syrus::PluginRegistry.snapshot }
  let(:repository) { Factories.repository }
  let(:job) { Factories.job(repository: repository) }

  before { Syrus::PluginRegistry.restore(snapshot.with(plugins: [], direct_providers: {})) }
  after { Syrus::PluginRegistry.restore(snapshot) }

  it "is registered while the plugin's providers are present" do
    Syrus::PluginRegistry.restore(snapshot)

    expect(Syrus::PluginRegistry.providers_for(:work_gate)).to include(MainBranchHealthProvider)
    expect(Syrus::PluginRegistry.providers_for(:repair_classifier)).to include(MainBranchHealthProvider)
  end

  it "applies no work gate and does not pause landing" do
    expect(WorkGates.evaluate(job: job)).to be_pass
    expect(WorkGates.evaluate(job: job).veto_for(StepDispatcher::MAIN_HEALTH_BLOCK_REASON)).to be_nil
  end

  it "raises no main-health alerts" do
    expect { SystemAlerts.active_for(user: nil) }.not_to raise_error
  end

  it "claims no repair classification" do
    expect(RepairClassifiers.classify(workflow: job.workflows.first, failed_steps: [])).to be_nil
  end
end
