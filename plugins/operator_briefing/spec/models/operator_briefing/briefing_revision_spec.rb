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

  it "accepts chart, artifact, image, and narrative dive candidate blocks" do
    revision.append_block!(
      "kind" => "narrative",
      "payload" => {
        "text" => "A cross-workflow architecture change happened.",
        "dive_candidates" => [
          { "text" => "architecture change", "prompt" => "Explain the change", "evidence" => [ { "workflow_id" => 1 } ] }
        ]
      }
    )
    revision.append_block!("kind" => "chart", "payload" => { "chart_type" => "count_by_severity", "data" => [ { "label" => "FYI", "value" => 2 } ] })
    revision.append_block!("kind" => "image", "payload" => { "workflow_id" => 12, "type" => "visual_review_screenshot_run_12_1" })
    revision.append_block!("kind" => "artifact", "payload" => { "workflow_id" => 12, "type" => "rails_schema_erd" })

    expect(revision.reload.content_blocks.map { |block| block["kind"] }).to eq(%w[narrative chart image artifact])
    expect(revision.content_blocks.first.dig("payload", "dive_candidates").sole).to include(
      "text" => "architecture change",
      "prompt" => "Explain the change",
      "evidence" => [ { "workflow_id" => 1 } ]
    )
  end

  it "normalizes Design Doc link card paths while preserving visible DOC refs" do
    block = revision.append_block!(
      "kind" => "link_card",
      "payload" => {
        "entity_type" => "design_doc",
        "entity_id" => 29,
        "title" => "DOC-29: Public release readiness",
        "path" => "/design_docs/DOC-29?from=briefing",
        "description" => "Review DOC-29 before filing follow-up work."
      }
    )

    expect(block.fetch("payload")).to include(
      "title" => "DOC-29: Public release readiness",
      "path" => "/design_docs/29?from=briefing",
      "description" => "Review DOC-29 before filing follow-up work."
    )
  end
end
