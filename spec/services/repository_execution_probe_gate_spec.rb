require "rails_helper"

RSpec.describe RepositoryExecutionProbeGate do
  it "blocks only the first initial implementation until the operator overrides the probe" do
    user = Factories.user
    repository = Factories.repository(user:)
    job = Factories.job(user:, repository:)
    workflow = job.workflows.first
    probe = RepositoryExecutionProbe.create!(repository:, requested_by: user, status: "blocked", result: { "summary" => "missing executable" })

    expect(described_class.blocking_probe_for(workflow)).to eq(probe)

    probe.update!(warning_override: true)
    expect(described_class.blocking_probe_for(workflow)).to be_nil
  end
end
