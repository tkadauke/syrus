require "rails_helper"

RSpec.describe OperatorBriefing::McpToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let!(:operator_briefing_plugin) do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:workflow) { OperatorBriefing::Workflow.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "briefing_generate_run") }
  let(:run) { Run.create!(job: job, user: user, step: step, trigger_kind: "briefing_generate", agent_provider: user.agent_provider) }
  let(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: Time.current
    )
  end
  let!(:revision) do
    OperatorBriefing::BriefingRevision.create!(
      briefing: briefing,
      generation_run: run,
      revision_number: 1,
      generated_at: Time.current,
      content_blocks: []
    )
  end

  before do
    allow(AppUserChannel).to receive(:broadcast_to)
  end

  def context_for(step_kind)
    instance_double(McpToolContext, run?: true, run: instance_double(Run, step: instance_double(Step, kind: step_kind)))
  end

  it "advertises submit_briefing_block only for briefing generation runs" do
    expect(described_class.tool_definitions(context: context_for("briefing_generate_run")).map { |definition| definition[:name] })
      .to eq([ "submit_briefing_block" ])
    expect(described_class.tool_definitions(context: context_for("implement"))).to eq([])
  end

  it "appends submitted blocks to the current generated revision" do
    response = described_class.new.handle(
      "submit_briefing_block",
      {
        "kind" => "narrative",
        "payload" => { "text" => "Live section" }
      },
      { run_id: run.id }
    )

    expect(response).not_to be_error
    expect(revision.reload.content_blocks).to eq([
      { "kind" => "narrative", "payload" => { "text" => "Live section" } }
    ])
    expect(AppUserChannel).to have_received(:broadcast_to).with(user, hash_including("resource" => "operator_briefing"))
  end

  it "rejects calls before the generation revision exists" do
    revision.destroy!

    response = described_class.new.handle(
      "submit_briefing_block",
      {
        "kind" => "narrative",
        "payload" => { "text" => "Too early" }
      },
      { run_id: run.id }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("no active Operator Briefing revision")
  end
end
