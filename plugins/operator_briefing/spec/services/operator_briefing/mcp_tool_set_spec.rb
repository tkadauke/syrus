require "rails_helper"

RSpec.describe OperatorBriefing::McpToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  def context_for(run)
    instance_double(McpToolContext, run?: true, run: run)
  end

  def briefing_run
    job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    workflow = OperatorBriefing::Workflow.instantiate(job: job)
    step = workflow.steps.find_by!(kind: "briefing_generate_run")
    step.runs.create!(job: job, user: user, trigger_kind: "briefing_generate", agent_provider: user.agent_provider)
  end

  def ordinary_run
    job = Factories.job(user: user, repository: repository)
    step = Step.create!(workflow: job.latest_workflow, kind: "implement", position: 99)
    step.runs.create!(job: job, user: user, trigger_kind: job.latest_workflow.trigger_kind, agent_provider: user.agent_provider)
  end

  it "advertises briefing tools to briefing generation runs" do
    names = described_class.tool_definitions(context: context_for(briefing_run)).map { |definition| definition[:name] }

    expect(names).to contain_exactly("submit_briefing_block", "read_briefing_git_diff", "list_briefing_recent_workflows")
  end

  it "does not advertise briefing tools to other workflow runs" do
    expect(described_class.tool_definitions(context: context_for(ordinary_run))).to eq([])
  end
end
