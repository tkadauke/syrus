require "rails_helper"

RSpec.describe TerminalSessionJob, type: :job do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }

  def terminal_session(**attrs)
    Terminal::Session.create!(
      {
        user: user,
        name: "scratch",
        working_directory: Rails.root.to_s,
        started_at: Time.current
      }.merge(attrs)
    )
  end

  it "enqueues on the chat queue" do
    expect {
      described_class.perform_later(123)
    }.to have_enqueued_job(described_class).with(123).on_queue("chat")
  end

  it "starts a bash terminal relay for a running session" do
    session = terminal_session
    relay = instance_double(Terminal::Relay, run: true)

    allow(ProcessRunner).to receive(:forwarded_env).with([]).and_return({ "TERM" => "xterm-256color" })
    expect(Terminal::Relay).to receive(:new).with(
      session: session,
      command: [ "bash" ],
      env: { "TERM" => "xterm-256color" }
    ).and_return(relay)

    described_class.perform_now(session.id)

    expect(relay).to have_received(:run)
    expect(session.reload.relay_started_at).to be_present
  end

  it "does not start a relay for a finished session" do
    session = terminal_session(finished_at: Time.current, outcome: "exited")

    expect(Terminal::Relay).not_to receive(:new)

    described_class.perform_now(session.id)
  end

  it "finishes the session without raising when the working directory is gone" do
    session = terminal_session(working_directory: "/nonexistent/terminal/workspace")

    expect(Terminal::Relay).not_to receive(:new)

    expect { described_class.perform_now(session.id) }.not_to raise_error
    expect(session.reload.finished_at).to be_present
    expect(session.outcome).to eq("exited")
    expect(session.relay_started_at).to be_nil
  end

  it "does not overwrite the outcome of a session killed after the initial check" do
    session = terminal_session(working_directory: "/nonexistent/terminal/workspace")
    allow(Terminal::Session).to receive(:find).with(session.id).and_return(session)
    allow(session).to receive(:finished?) do
      Terminal::Session.where(id: session.id).update_all(finished_at: Time.current, outcome: "killed")
      false
    end

    described_class.perform_now(session.id)

    expect(Terminal::Session.find_by(id: session.id).outcome).to eq("killed")
  end
end
