require "rails_helper"

RSpec.describe OperatorBriefing::BriefingRevision do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", priority: "low") }
  let(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: Time.current
    )
  end
  let(:revision) do
    described_class.create!(
      briefing: briefing,
      revision_number: 1,
      generated_at: Time.current,
      content_blocks: []
    )
  end

  before do
    allow(AppUserChannel).to receive(:broadcast_to)
  end

  it "appends a block and broadcasts the live briefing event" do
    block = revision.append_block!(
      "kind" => "narrative",
      "payload" => { "text" => "First section" }
    )

    expect(block).to eq("kind" => "narrative", "payload" => { "text" => "First section" })
    expect(revision.reload.content_blocks).to eq([ block ])
    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "operator_briefing.block_submitted",
        "resource" => "operator_briefing",
        "id" => briefing.id,
        "changed" => [ "revision.content_blocks" ],
        "payload" => hash_including(
          "briefing_id" => briefing.id,
          "revision_id" => revision.id,
          "block" => block
        )
      )
    )
  end
end
