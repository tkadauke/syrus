require "rails_helper"

RSpec.describe AgentInsights::WorkDefinition do
  def enable!(enabled)
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: enabled, disableable: true)
  end

  it "registers the agent_insight work definition while the plugin is enabled" do
    enable!(true)

    definition = WorkDefinitions.for("agent_insight")

    expect(definition).to be_a(described_class)
    expect(definition).to be_infrastructure
    expect(definition.workflow_trigger_kind).to eq("agent_insight")
    expect(definition.scope).to eq("repository")
    expect(definition.lock_scope).to eq("none")
    expect(definition.lock_conflicts_enforced?).to be(true)
    expect(definition.manages_own_job_lifecycle?).to be(true)
  end

  it "uses a sweep-specific repository key instead of the exclusive repository mutex" do
    enable!(true)
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")

    definition = WorkDefinitions.for("agent_insight")
    keys = definition.lock_keys_for(job: job, member_jobs: [ job ], artifacts: {})

    expect(definition.scope_for(job: job, artifacts: {})).to have_attributes(type: "repository", id: repository.id)
    expect(keys).to contain_exactly("job:#{job.id}", "agent_insight:repository:#{repository.id}")
    expect(keys).not_to include("repository:#{repository.id}", "landing:repository:#{repository.id}")
  end

  it "leaves the registry consistent when the plugin is disabled" do
    enable!(true)
    expect(WorkDefinitions.registry).to have_key("agent_insight")

    enable!(false)

    # The definition disappears together with the trigger kind it points at,
    # so the registry never holds a definition for an unknown trigger.
    expect(WorkDefinitions.registry).not_to have_key("agent_insight")
    expect(Workflow::TriggerKind.values).not_to include("agent_insight")
    expect(WorkDefinitions::RegistryValidator.call).to eq([])
  end

  it "contributes the agent_insight Job kind as issueless infrastructure" do
    enable!(true)

    expect(Job::Kind.values).to include("agent_insight")
    expect(Job::Kind.infrastructure_values).to include("agent_insight")
    expect(Job::Kind.issueless?("agent_insight")).to be(true)

    enable!(false)

    expect(Job::Kind.values).not_to include("agent_insight")
  end

  it "keeps insight Jobs out of the operator's user-facing Job lists" do
    enable!(true)
    user = Factories.user
    repository = Factories.repository(user: user)
    insight_job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")

    expect(Filters::Chips::Jobs::JobType.system_kinds).to include("agent_insight")
    expect(Filters::Chips::Jobs::JobType.user_kinds).not_to include("agent_insight")
    expect(Job.where(kind: Filters::Chips::Jobs::JobType.user_kinds)).not_to include(insight_job)
  end

  it "rejects an insight Job that carries a GitHub issue number" do
    enable!(true)
    user = Factories.user
    repository = Factories.repository(user: user)

    job = Job.new(user: user, repository: repository, kind: "agent_insight", priority: "low", issue_number: 7)

    expect(job).not_to be_valid
    expect(job.errors[:issue_number]).to include("must be blank for agent_insight Jobs")
  end

  it "does not block job bundle landing while an insight sweep is running" do
    enable!(true)

    result = WorkEngine::Simulation::ScenarioRunner.call(
      path: Rails.root.join("spec/fixtures/work_engine_simulations/agent_insight_sweep_does_not_block_job_bundle.yml"),
      max_ticks: 50
    )

    expect(result).to be_success
    expect(result.events.join("\n")).to include("merge_train_land")
  end
end
