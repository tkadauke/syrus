require "rails_helper"

RSpec.describe CognitiveEngagementEvent do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def build_event(**attrs)
    described_class.new({
      repository: repository,
      user: user,
      source_type: "diff_review_comment",
      engagement_kind: "reviewed",
      evidence_type: "DiffReviewComment",
      evidence_id: 123,
      evidence_key: "diff_review_comment:123",
      occurred_at: Time.zone.parse("2026-09-28 10:00:00 UTC"),
      base_sha: "base-sha",
      head_sha: "head-sha",
      path: " app/models/widget.rb ",
      side: "right",
      start_line: 14,
      end_line: 12,
      metadata: { "comment_state" => "submitted" }
    }.merge(attrs))
  end

  it "stores a normalized range-level engagement event" do
    event = build_event

    expect(event.save).to be true
    expect(event).to have_attributes(
      path: "app/models/widget.rb",
      start_line: 12,
      end_line: 14,
      anchor_key: "range:app/models/widget.rb:right:12:14",
      weight: BigDecimal("0.8")
    )
  end

  it "keeps weights as controlled engagement-kind defaults" do
    expect(described_class.default_weight_for("authored")).to eq(BigDecimal("1.0"))
    expect(described_class.default_weight_for("reviewed")).to eq(BigDecimal("0.8"))
    expect(described_class.default_weight_for("approved")).to eq(BigDecimal("0.5"))
    expect(described_class.default_weight_for("discussed")).to eq(BigDecimal("0.3"))
    expect(described_class.default_weight_for("viewed")).to eq(BigDecimal("0.2"))
  end

  it "allows confidence and quality metadata for later downweighting" do
    event = build_event(
      source_type: "job_approval",
      engagement_kind: "approved",
      evidence_type: "JobApproval",
      evidence_key: "job_approval:7",
      anchor_kind: "repository",
      path: nil,
      side: nil,
      start_line: nil,
      end_line: nil,
      confidence: BigDecimal("0.35"),
      quality: "rubber_stamp",
      metadata: { "elapsed_seconds" => 2 }
    )

    expect(event.save).to be true
    expect(event.anchor_key).to eq("repository")
    expect(event.weight).to eq(BigDecimal("0.5"))
    expect(event.confidence).to eq(BigDecimal("0.35"))
    expect(event.quality).to eq("rubber_stamp")
    expect(event.metadata).to eq("elapsed_seconds" => 2)
  end

  it "validates source, engagement kind, anchor shape, and score bounds" do
    event = build_event(
      source_type: "unknown",
      engagement_kind: "skimmed",
      path: "",
      start_line: nil,
      end_line: nil,
      weight: BigDecimal("1.1"),
      confidence: BigDecimal("-0.1")
    )

    expect(event).not_to be_valid
    expect(event.errors[:source_type]).to be_present
    expect(event.errors[:engagement_kind]).to be_present
    expect(event.errors[:path]).to include("must be present for range anchors")
    expect(event.errors[:start_line]).to include("must be present for range anchors")
    expect(event.errors[:end_line]).to include("must be present for range anchors")
    expect(event.errors[:weight]).to be_present
    expect(event.errors[:confidence]).to be_present
  end

  it "requires an optional diff review version to belong to the same repository" do
    other_repository = Factories.repository(user: user)
    other_job = Factories.job_record(repository: other_repository, user: user, issue_number: 99)
    version = DiffReviewVersion.create!(
      job: other_job,
      version_index: 1,
      base_sha: "base",
      head_sha: "head",
      source_key: "spec",
      files_snapshot: [],
      metadata: {}
    )

    event = build_event(diff_review_version: version)

    expect(event).not_to be_valid
    expect(event.errors[:diff_review_version]).to include("must belong to the same repository")
  end
end
