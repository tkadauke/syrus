require "rails_helper"

RSpec.describe OperatorBriefing::Feedback, type: :model do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low") }
  let(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: 1.day.ago,
      window_end: Time.current
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "writes explicit feedback as a global user preference memory" do
    feedback = described_class.create!(
      user: user,
      briefing: briefing,
      sentiment: "negative",
      note: "Spend cards are not useful here."
    )

    memory = feedback.memory_entry
    expect(memory).to have_attributes(
      user: user,
      kind: "user_pref",
      scope: "global",
      scope_id: nil,
      confidence: be_within(0.001).of(0.65)
    )
    expect(memory.content).to include("explicit feedback", repository.slug, "Spend cards are not useful here")
  end

  it "records completed dives as stronger interest signals" do
    memory = OperatorBriefing::InterestSignal.record_dive_completed!(
      user: user,
      briefing: briefing,
      topic_title: "Architecture shift"
    )

    expect(memory).to have_attributes(
      kind: "user_pref",
      scope: "global",
      confidence: be_within(0.001).of(0.9)
    )
    expect(memory.content).to include("completed dive", "Architecture shift")
  end

  it "requires sentiment or note" do
    feedback = described_class.new(user: user, briefing: briefing)

    expect(feedback).not_to be_valid
    expect(feedback.errors[:base]).to include("sentiment or note is required")
  end
end
