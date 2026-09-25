require "rails_helper"

RSpec.describe AgentInsights::McpToolSet do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true)
  end

  def context_for(role)
    instance_double(McpToolContext, role: role)
  end

  def tool_names_for(role)
    described_class.tool_definitions(context: context_for(role)).map { |definition| definition[:name] }
  end

  def workflow_run_for(kind)
    job = Factories.job(user: user, repository: repository)
    step = Step.create!(workflow: job.latest_workflow, kind: kind, position: 99)
    step.runs.create!(job: job, trigger_kind: job.latest_workflow.trigger_kind)
  end

  def insight_run
    job = Job.create!(user: user, repository: repository, kind: "agent_insight", priority: "low")
    workflow = AgentInsights::Workflow.instantiate(job: job)
    step = workflow.steps.find_by!(kind: "agent_insight_run")
    step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end

  it "advertises every workflow insight tool to the agent insight role" do
    expect(tool_names_for(AgentRole::AGENT_INSIGHT)).to match_array(
      %w[
        submit_insight
        update_insight
        retire_insight
        list_insights
        read_insight
        read_run_transcript
        list_recent_workflows
      ]
    )
  end

  it "does not advertise workflow insight tools to ordinary workflow roles" do
    AgentRole::WORKFLOW_ROLES.each do |role|
      expect(tool_names_for(role)).to eq([])
    end
  end

  it "is unavailable for non-insight workflow contexts" do
    AgentRole::WORKFLOW_ROLES.each do |role|
      expect(described_class.available_for_context?(context_for(role))).to be(false)
    end
  end

  it "is available for agent insight workflow contexts" do
    expect(described_class.available_for_context?(context_for(AgentRole::AGENT_INSIGHT))).to be(true)
  end

  it "rejects denied workflow calls before dispatching mutating insight tools" do
    run = workflow_run_for("implement")

    expect {
      response = described_class.new.handle(
        "submit_insight",
        {
          "title" => "Ordinary workflow should not file this",
          "category" => "repeated_failure",
          "severity" => "medium",
          "confidence" => 0.8
        },
        { run: run }
      )

      expect(response).to be_error
      expect(response.content.first[:text]).to include("Unknown Agent Insights tool")
    }.not_to change(AgentInsights::Suggestion, :count)
  end

  it "still dispatches insight tools for the agent insight role" do
    response = described_class.new.handle(
      "list_insights",
      {},
      { run: insight_run }
    )

    expect(response).not_to be_error
    expect(response.content.first[:text]).to include("insights")
  end
end
