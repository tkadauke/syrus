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

  describe "a git: block" do
    let(:scenario_path) do
      Rails.root.join("spec/fixtures/work_engine_simulations/stack_rebase_after_parent_landed_targets_merged_base.yml")
    end

    it "builds the commit DAG, merges a seeded merged PR, and retargets the PRs based on its branch" do
      world = described_class.load!(scenario_path)
      git = world.git_world
      child = world.jobs_by_key.fetch("child")

      expect(git.branch?("syrus/parent")).to be(false)
      expect(git.pull_request(801)).to have_attributes(merged: true, state: "closed")
      expect(git.pull_request(child.pr_number).base_branch).to eq("main")
      expect(git.pull_request(803).base_branch).to eq("syrus/child")
      expect(git.range("main").map(&:patch)).to include("parent_1", "teammate")
    end

    it "substitutes git:<label> references with commit ids" do
      path = Rails.root.join("spec/fixtures/work_engine_simulations/stack_child_retry_replays_only_own_commits.yml")
      world = described_class.load!(path)
      child = world.jobs_by_key.fetch("child")
      retry_workflow = child.workflows.find_by!(trigger_kind: "retry")

      expect(retry_workflow.artifact("stack_base_prepared")["sha"]).to eq(world.git_world.sha_for("parent_new"))
      expect(world.git_world.checkout(child.id).head).to eq(world.git_world.sha_for("child_1"))
      expect(child.workflows.find_by!(trigger_kind: "initial").artifact("stack_base_rebase_conflict")["prepared_sha"])
        .to eq(world.git_world.sha_for("parent_old"))
    end
  end

  it "leaves every seeded provider available until a scenario says otherwise" do
    world = described_class.load!(scenario_path)

    User.agent_providers.each do |provider|
      expect(App::ProviderAvailability.for_user(world.user, provider, cached: false))
        .to include(state: "available"), "expected #{provider} to start available"
    end
  end
end
