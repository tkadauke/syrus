require "rails_helper"

RSpec.describe InsightSuggestionAuditEvent do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(user: user, repository: repository) }
  let(:insight) do
    InsightSuggestion.create!(
      job: job,
      repository: repository,
      title: "Insight",
      category: "configuration",
      severity: "low",
      confidence: 0.5
    )
  end

  it "records user actor context" do
    event = described_class.record!(
      insight_suggestion: insight,
      event_type: "updated",
      actor: user,
      previous_values: { "title" => "Old" },
      new_values: { "title" => "New" },
      reason: "Operator edited the suggestion."
    )

    expect(event.actor_kind).to eq("user")
    expect(event.actor_user).to eq(user)
    expect(event.actor_run).to be_nil
  end

  it "is append-only" do
    event = described_class.record!(
      insight_suggestion: insight,
      event_type: "updated",
      actor: nil,
      previous_values: { "title" => "Old" },
      new_values: { "title" => "New" },
      reason: "System migration."
    )

    expect { event.update!(reason: "Changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
