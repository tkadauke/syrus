require "rails_helper"

RSpec.describe OperatorBriefing::Scheduler do
  # 15 minutes after the default cadence ("0 9 * * 1") fires on a Monday, so
  # `now` sits inside the one-hour due window. The cadence is interpreted in
  # BriefingSettings::CADENCE_TIMEZONE, not the process's zone -- see the
  # zone-independence example below.
  let(:now) { Time.zone.parse("2026-10-05 09:15:00 UTC") }
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

  # Regression: the cadence used to be parsed without a timezone, and Fugit
  # resolves an unqualified expression against the process's local zone. The
  # same stored cadence therefore named 09:00 Eastern where TZ was set and
  # 09:00 UTC in CI, so scheduled briefings fired an hour-window apart
  # depending only on container configuration.
  it "resolves the cadence independently of the process timezone" do
    OperatorBriefing::BriefingSubscription.create!(user: user, repository: repository, enabled: true)
    settings = OperatorBriefing::BriefingSettings.for_user(user)

    due = %w[UTC America/New_York Australia/Sydney].map do |zone|
      with_process_timezone(zone) { settings.due?(now: now) }
    end

    expect(due).to all(be true)
  end

  def with_process_timezone(zone)
    previous = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    ENV["TZ"] = previous
  end

  it "does not treat a settings payload read as scheduled opt-in" do
    OperatorBriefing::Payload.new(user: user).as_json

    described_class.run!(now: now)

    expect(OperatorBriefing::Generator).not_to have_received(:generate!)
    expect(OperatorBriefing::BriefingSettings.find_by(user: user)).to be_present
    expect(OperatorBriefing::BriefingSubscription.find_by!(user: user, repository: repository)).not_to be_enabled
  end
end
