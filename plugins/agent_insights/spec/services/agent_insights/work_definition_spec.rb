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
    expect(definition.manages_own_job_lifecycle?).to be(true)
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
end
