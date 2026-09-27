require "rails_helper"

RSpec.describe OperatorBriefing::Workflow do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, repository: repository, owner_user: user, kind: "briefing_generate", priority: "low") }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "materializes prepare before briefing generation and leaves out auto-close" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.trigger_kind).to eq("briefing_generate")
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare briefing_generate_run])
    expect(Step::Kind.by_kind.fetch("briefing_generate_run").agentic).to eq(true)
    expect(Step::Kind.by_kind.fetch("briefing_generate_run").required_mcp_tools).to eq(%w[submit_briefing_block])
  end

  it "contributes an issueless infrastructure job kind and work definition" do
    expect(Job::Kind.infrastructure_values).to include("briefing_generate")
    expect(Job::Kind.issueless?("briefing_generate")).to be(true)

    definition = WorkDefinitions.for("briefing_generate")
    expect(definition).to be_a(OperatorBriefing::WorkDefinition)
    expect(definition).to be_infrastructure
    expect(definition.workflow_trigger_kind).to eq("briefing_generate")
    expect(definition.scope).to eq("repository")
  end
end
