require "rails_helper"

RSpec.describe Terminal::KillSession do
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

  it "marks a running session finished with outcome killed" do
    session = build_session

    described_class.call(session)

    expect(session.outcome).to eq("killed")
    expect(session.finished_at).to be_present
    expect(session.running?).to eq(false)
  end

  it "is a no-op for an already-finished session" do
    finished_at = 1.hour.ago
    session = build_session(finished_at: finished_at, outcome: "exited")

    described_class.call(session)

    expect(session.outcome).to eq("exited")
    expect(session.finished_at).to be_within(1.second).of(finished_at)
  end

  it "returns the session" do
    session = build_session

    expect(described_class.call(session)).to eq(session)
  end
end
