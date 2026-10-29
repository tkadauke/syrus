require "rails_helper"

RSpec.describe Coworkers::WorkflowKinds do
  def enable!(enabled)
    PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: enabled, disableable: true)
  end

  it "loads and unloads the coworker Job, trigger, step, and work-definition entries with the plugin" do
    enable!(true)

    expect(Job::Kind.values).to include("coworker_task")
    expect(Job::Kind.infrastructure_values).to include("coworker_task")
    expect(Job::Kind.issueless?("coworker_task")).to be(true)
    expect(Workflow::TriggerKind.by_kind.fetch("coworker_run")).to have_attributes(
      runtime_role: "infrastructure", owns_job_lifecycle: true
    )
    expect(Step::Kind.by_kind.fetch("coworker_run")).to have_attributes(agentic: true, agent_role: AgentRole::COWORKER)
    expect(Step::Kind.by_kind.fetch("post_to_chat")).to have_attributes(agentic: false)
    expect(WorkDefinitions.for("coworker_run")).to be_a(Coworkers::WorkDefinition)

    enable!(false)

    expect(Job::Kind.values).not_to include("coworker_task")
    expect(Workflow::TriggerKind.values).not_to include("coworker_run")
    expect(Step::Kind.values).not_to include("coworker_run", "post_to_chat")
    expect(WorkDefinitions.registry).not_to have_key("coworker_run")
    expect(WorkDefinitions::RegistryValidator.call).to eq([])
  end
end
