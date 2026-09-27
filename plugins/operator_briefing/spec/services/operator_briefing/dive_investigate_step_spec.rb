require "rails_helper"

RSpec.describe OperatorBriefing::DiveInvestigateStep do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:workflow) do
    OperatorBriefing::DiveWorkflow.instantiate(
      job: job,
      artifacts: {
        "briefing_dive_context" => {
          "selected_text" => "migration risk",
          "prompt" => "Explain this migration",
          "evidence" => [ { "workflow_id" => 123 } ]
        }
      }
    )
  end
  let(:step) { workflow.steps.find_by!(kind: "briefing_dive_investigate") }
  let(:run) { Run.create!(job: job, user: user, step: step, trigger_kind: "briefing_dive", agent_provider: user.agent_provider) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "invokes the agent with the briefing reader required" do
    step_handler = described_class.new(run)
    allow(step_handler).to receive(:run_agent)
    allow(step_handler).to receive(:workspace).and_return(double(setup: true))

    step_handler.call

    expect(run.reload.prompt).to include("read_briefing", "migration risk", "Explain this migration")
    expect(step_handler).to have_received(:run_agent).with(
      prompt: run.prompt,
      required_mcp_tools: %w[read_briefing]
    )
  end
end
