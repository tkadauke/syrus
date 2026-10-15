require "rails_helper"

RSpec.describe WorkEngine::Simulation::ScenarioLoader do
  let(:scenario_path) do
    Rails.root.join("spec/fixtures/work_engine_simulations/single_initial_success.yml")
  end

  # Regression: the simulated user carries placeholder provider credentials so
  # that auth preflights pass, and the admission path asks each provider to
  # refresh stale usage. For Claude that is an HTTP POST to the real API, which
  # answered the placeholder token with 401 -- recorded as auth_error evidence,
  # which then blocked admission for a reason no scenario had declared. A
  # scenario's outcome depended on the host's credentials, and every simulator
  # run reached the network.
  it "seeds a fresh probe result per provider so no scenario refreshes usage over the network" do
    world = described_class.load!(scenario_path)

    expect(User.agent_providers).not_to be_empty
    expect(
      ProviderAvailabilityEvidence.where(user: world.user, source: "usage_probe").pluck(:provider, :status).to_h
    ).to eq(User.agent_providers.index_with("available"))

    expect {
      User.agent_providers.each do |provider|
        AgentProviders.for(provider).refresh_stale_usage!(user: world.user)
      end
    }.not_to change { ProviderAvailabilityEvidence.where(user: world.user).count }
  end

  it "leaves every seeded provider available until a scenario says otherwise" do
    world = described_class.load!(scenario_path)

    User.agent_providers.each do |provider|
      expect(App::ProviderAvailability.for_user(world.user, provider, cached: false))
        .to include(state: "available"), "expected #{provider} to start available"
    end
  end
end
