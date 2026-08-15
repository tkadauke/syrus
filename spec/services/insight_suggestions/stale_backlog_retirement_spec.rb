require "rails_helper"

RSpec.describe InsightSuggestions::StaleBacklogRetirement do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(user: user, repository: repository) }

  def insight(**attrs)
    InsightSuggestion.create!({
      job: job,
      repository: repository,
      title: "Finding",
      category: "configuration",
      severity: "low",
      confidence: 0.4
    }.merge(attrs))
  end

  it "retires pending legacy revise_existing_insight rows" do
    target_insight = insight(title: "Target")
    legacy = insight(proposal_type: "revise_existing_insight", target_insight: target_insight)

    result = described_class.new.call

    expect(legacy.reload.state).to eq("retired")
    expect(legacy.retired_reason).to be_present
    expect(result.retired).to eq(1)
    expect(result.checked).to eq(1)
  end

  it "retires pending informational 'Superseded by #' rows" do
    stale = insight(title: "Superseded by #42", proposal_type: "informational")

    result = described_class.new.call

    expect(stale.reload.state).to eq("retired")
    expect(result.retired).to eq(1)
  end

  it "retires dismissed matches too" do
    stale = insight(title: "Superseded by #7", proposal_type: "informational", state: "dismissed", dismissed_at: 1.hour.ago)

    described_class.new.call

    expect(stale.reload.state).to eq("retired")
  end

  it "does not touch unrelated informational rows" do
    unrelated = insight(title: "Prepare fails intermittently", proposal_type: "informational")

    described_class.new.call

    expect(unrelated.reload.state).to eq("pending")
  end

  it "does not touch accepted rows even if they match the legacy pattern" do
    target_insight = insight(title: "Target")
    accepted = insight(proposal_type: "revise_existing_insight", target_insight: target_insight, state: "accepted", accepted_at: 1.hour.ago)

    described_class.new.call

    expect(accepted.reload.state).to eq("accepted")
  end

  it "does not persist changes in dry_run mode" do
    target_insight = insight(title: "Target")
    legacy = insight(proposal_type: "revise_existing_insight", target_insight: target_insight)

    result = described_class.new.call(dry_run: true)

    expect(legacy.reload.state).to eq("pending")
    expect(result.retired).to eq(1)
  end

  it "records an audit event with a system actor for each retirement" do
    target_insight = insight(title: "Target")
    legacy = insight(proposal_type: "revise_existing_insight", target_insight: target_insight)

    expect {
      described_class.new.call
    }.to change(InsightSuggestionAuditEvent, :count).by(1)

    event = legacy.reload.audit_events.last
    expect(event.event_type).to eq("retired")
    expect(event.actor_kind).to eq("system")
  end
end
