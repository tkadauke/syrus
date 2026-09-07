require "rails_helper"

RSpec.describe Terminal::AdminSessionSerializer do
  let(:user) { Factories.user }

  def build_session(**attrs)
    Terminal::Session.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current,
      **attrs
    )
  end

  it "includes the base session fields plus admin-only fields, never the auth token" do
    session = build_session(relay_address: "10.0.0.5:41000", started_at: 90.seconds.ago)

    payload = described_class.render(session)

    expect(payload).to include(
      id: session.id,
      name: "Shell",
      relay_address: "10.0.0.5:41000",
      hostname: "10.0.0.5",
      state: "running",
      user: { id: user.id, email_address: user.email_address }
    )
    expect(payload[:age_s]).to be >= 90
    expect(payload).not_to have_key(:auth_token)
  end

  it "reports state finished and a bounded age for a finished session" do
    session = build_session(started_at: 2.hours.ago, finished_at: 1.hour.ago, outcome: "exited")

    payload = described_class.render(session)

    expect(payload[:state]).to eq("finished")
    expect(payload[:age_s]).to be_within(2).of(1.hour.to_i)
  end

  it "degrades to error_serializing instead of raising when a field blows up" do
    session = build_session
    allow(session).to receive(:relay_address).and_raise(StandardError, "boom")

    payload = described_class.render(session)

    expect(payload).to eq(id: session.id, error_serializing: "StandardError: boom")
  end
end
