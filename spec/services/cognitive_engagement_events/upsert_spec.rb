require "rails_helper"

RSpec.describe CognitiveEngagementEvents::Upsert do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:occurred_at) { Time.zone.parse("2026-09-28 12:00:00 UTC") }

  def upsert(**attrs)
    described_class.call(**{
      repository: repository,
      user: user,
      source_type: "viewed_range",
      engagement_kind: "viewed",
      evidence_type: "ChatMessage",
      evidence_id: 456,
      evidence_key: "chat_message:456:file:app/models/widget.rb",
      occurred_at: occurred_at,
      commit_sha: "head-sha",
      path: "app/models/widget.rb",
      start_line: 8,
      end_line: 4,
      confidence: BigDecimal("0.4"),
      quality: "shallow",
      metadata: { "visible_milliseconds" => 800 }
    }.merge(attrs))
  end

  it "creates an event through the normalized model shape" do
    event = upsert

    expect(event).to be_persisted
    expect(event.reload).to have_attributes(
      anchor_kind: "range",
      anchor_key: "range:app/models/widget.rb::4:8",
      start_line: 4,
      end_line: 8,
      weight: BigDecimal("0.2"),
      quality: "shallow"
    )
  end

  it "updates an existing evidence/range event instead of duplicating it" do
    first = upsert(metadata: { "visible_milliseconds" => 800 }, confidence: BigDecimal("0.4"))
    second = upsert(metadata: { "visible_milliseconds" => 2_500 }, confidence: BigDecimal("0.7"))

    expect(second.id).to eq(first.id)
    expect(CognitiveEngagementEvent.count).to eq(1)
    expect(first.reload).to have_attributes(
      confidence: BigDecimal("0.7"),
      metadata: { "visible_milliseconds" => 2_500 }
    )
  end

  it "preserves separate range events from the same evidence reference" do
    upsert(start_line: 1, end_line: 3)
    upsert(start_line: 10, end_line: 12)

    expect(CognitiveEngagementEvent.pluck(:anchor_key)).to contain_exactly(
      "range:app/models/widget.rb::1:3",
      "range:app/models/widget.rb::10:12"
    )
  end

  it "supports current-HEAD file anchors without a diff base/head pair" do
    event = upsert(
      source_type: "authored_line",
      engagement_kind: "authored",
      evidence_type: "GitCommit",
      evidence_key: "commit:head-sha:app/models/widget.rb",
      anchor_kind: "file",
      base_sha: nil,
      head_sha: nil,
      start_line: nil,
      end_line: nil
    )

    expect(event.anchor_key).to eq("file:app/models/widget.rb")
    expect(event.weight).to eq(BigDecimal("1.0"))
  end
end
