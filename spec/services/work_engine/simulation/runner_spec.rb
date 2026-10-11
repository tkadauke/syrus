require "rails_helper"

RSpec.describe WorkEngine::Simulation::Runner, :reset_plugin_registry do
  around do |example|
    Syrus::PluginRegistry.reset!
    example.run
    Syrus::PluginRegistry.reset!
  end

  it "resolves symbolic alternate providers when the agent-provider registry is empty" do
    runner = described_class.new(job_ids: [], scenario: "empty provider registry")

    expect(User.agent_providers).to be_empty

    provider = runner.send(:resolve_simulated_provider, "alternate")

    expect(provider).to eq("claude")
    expect(User.agent_providers).to include("claude")
    expect(AgentProviders.for(provider)).to respond_to(:refresh_stale_usage!)
  end

  it "does not count WorkUnits attached to terminal workflows as active queue work" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    runner = described_class.new(job_ids: [ job.id ], scenario: "terminal workflow work unit")

    expect(runner.send(:active_work_units)).to contain_exactly(workflow.work_unit)

    workflow.update_columns(state: "succeeded", finished_at: Time.current)

    expect(runner.send(:active_work_units)).to be_empty
  end
end
