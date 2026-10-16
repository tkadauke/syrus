require "rails_helper"

RSpec.describe Terminal::OrphanReaper do
  let(:user) { Factories.user }

  def terminal_session(**attrs)
    Terminal::Session.create!({ user: user, name: "scratch", working_directory: Rails.root.to_s, started_at: Time.current }.merge(attrs))
  end

  it "marks a started session whose relay never appeared as orphaned" do
    session = terminal_session(relay_started_at: 2.minutes.ago)

    described_class.run!

    expect(session.reload).to have_attributes(outcome: "orphaned", finished_at: be_present)
  end

  it "does not orphan a session delayed in its worker queue" do
    session = terminal_session(started_at: 2.hours.ago, relay_started_at: nil)

    described_class.run!

    expect(session.reload).to be_running
  end

  it "does not orphan a session when its relay is published during the sweep" do
    session = terminal_session(relay_started_at: 2.minutes.ago)
    allow_any_instance_of(described_class).to receive(:orphaned?).with(session) do
      session.update!(relay_address: "127.0.0.1:4444")
      true
    end

    described_class.run!

    expect(session.reload).to be_running
  end

  it "marks sessions with unreachable relays as orphaned" do
    session = terminal_session(relay_started_at: 1.minute.ago, relay_address: "127.0.0.1:4444")
    allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)

    described_class.run!

    expect(session.reload).to have_attributes(outcome: "orphaned", finished_at: be_present)
  end

  it "keeps reachable and recently-started sessions running" do
    reachable = terminal_session(relay_started_at: 1.minute.ago, relay_address: "127.0.0.1:4444")
    starting = terminal_session(relay_started_at: 30.seconds.ago)
    socket = instance_double(Socket, close: nil)
    allow(Socket).to receive(:tcp).and_yield(socket)

    described_class.run!

    expect(reachable.reload).to be_running
    expect(starting.reload).to be_running
  end
end
