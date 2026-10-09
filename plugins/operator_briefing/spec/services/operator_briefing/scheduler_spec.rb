require "rails_helper"

RSpec.describe OperatorBriefing::Scheduler do
  let(:now) { Time.zone.parse("2026-10-05 13:15:00 UTC") }
  let(:user) { Factories.user }
  let!(:repository) { Factories.repository(user: user) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    allow(OperatorBriefing::Generator).to receive(:generate!)
  end

  it "creates no work for a user with no opt-in records" do
    described_class.run!(now: now)

    expect(OperatorBriefing::Generator).not_to have_received(:generate!)
    expect(OperatorBriefing::BriefingSettings.where(user: user)).to be_empty
    expect(OperatorBriefing::BriefingSubscription.where(user: user)).to be_empty
  end

  it "creates scheduled work for explicitly enabled subscriptions" do
    OperatorBriefing::BriefingSubscription.create!(user: user, repository: repository, enabled: true)

    described_class.run!(now: now)

    expect(OperatorBriefing::Generator).to have_received(:generate!).with(
      user: user,
      repository: repository,
      mode: :scheduled,
      now: now
    )
    expect(OperatorBriefing::BriefingSettings.find_by!(user: user).last_scheduled_at).to eq(now)
  end

  it "does not treat a settings payload read as scheduled opt-in" do
    OperatorBriefing::Payload.new(user: user).as_json

    described_class.run!(now: now)

    expect(OperatorBriefing::Generator).not_to have_received(:generate!)
    expect(OperatorBriefing::BriefingSettings.find_by(user: user)).to be_present
    expect(OperatorBriefing::BriefingSubscription.find_by!(user: user, repository: repository)).not_to be_enabled
  end
end
