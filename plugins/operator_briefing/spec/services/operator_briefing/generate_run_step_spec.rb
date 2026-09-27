require "rails_helper"

RSpec.describe OperatorBriefing::GenerateRunStep do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:workflow) { OperatorBriefing::Workflow.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "briefing_generate_run") }
  let(:run) { Run.create!(job: job, user: user, step: step, trigger_kind: "briefing_generate", agent_provider: user.agent_provider) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    @briefing = OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: 1.hour.from_now
    )
  end

  it "creates an empty revision and invokes the agent with briefing instructions" do
    step_handler = described_class.new(run)
    allow(step_handler).to receive(:run_agent)
    allow(step_handler).to receive(:workspace).and_return(double(setup: true))

    step_handler.call

    revision = @briefing.revisions.sole
    expect(revision.generation_run).to eq(run)
    expect(revision.content_blocks).to eq([])
    expect(run.reload.prompt).to include("read_briefing_git_diff", "list_briefing_recent_workflows", "submit_briefing_block")
    expect(step_handler).to have_received(:run_agent).with(prompt: run.prompt, required_mcp_tools: %w[submit_briefing_block])
  end
end
