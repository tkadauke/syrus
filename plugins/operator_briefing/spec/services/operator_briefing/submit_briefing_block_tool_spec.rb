require "rails_helper"

RSpec.describe OperatorBriefing::Tools::SubmitBriefingBlockTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository) }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.create!(job: job, user: user, trigger_kind: workflow.trigger_kind, agent_provider: user.agent_provider) }
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
    briefing.revisions.create!(
      revision_number: 1,
      generated_at: Time.current,
      generation_run: run,
      content_blocks: []
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    Feature.clear_enabled_cache!("operator_briefing")
  end

  it "appends a narrative block to the current run revision" do
    response = described_class.call(
      kind: "narrative",
      payload: { "text" => "Schema changes need attention." },
      server_context: { run: run }
    )

    expect(response).not_to be_error, response.content.first[:text]
    expect(revision.reload.content_blocks).to eq([
      { "kind" => "narrative", "payload" => { "text" => "Schema changes need attention." } }
    ])
    expect(workflow.reload.artifact("briefing_revision_id")).to eq(revision.id)
  end

  it "rejects unsupported block kinds" do
    response = described_class.call(kind: "chart", payload: {}, server_context: { run: run })

    expect(response).to be_error
    expect(revision.reload.content_blocks).to eq([])
  end
end
