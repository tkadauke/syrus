require "rails_helper"
RSpec.describe Coworkers::RunContextContributor do
  it "hard-fails when the pinned reviewer plugin disappears" do
    job = instance_double(Job, owner_user: double, user: double, repository: double)
    run = instance_double(Run, job: job, step: instance_double(Step, details: { "reviewer_target" => { "type" => "coworker", "reference" => "gone" } }))
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:reviewer_target_provider).and_return([])
    expect { described_class.context_attributes(run: run, role: AgentRole::WORKFLOW_COWORKER_REVIEWER) }.to raise_error(ReviewerTargets::PluginUnavailable)
  end
end
