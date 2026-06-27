require "rails_helper"

RSpec.describe TerminalSessionJob do
  let(:user) { Factories.user }
  let(:session) do
    TerminalSession.create!(
      user: user,
      name: "scratch",
      working_directory: Rails.root.to_s,
      started_at: Time.current
    )
  end

  it "enqueues on the chat queue" do
    expect {
      described_class.perform_later(session.id)
    }.to have_enqueued_job(described_class).with(session.id).on_queue("chat")
  end

  it "starts a bash terminal relay for a running session" do
    relay = instance_double(TerminalRelay, run: true)

    expect(TerminalRelay).to receive(:new).with(
      session: session,
      command: [ "bash" ],
      env: ProcessRunner.forwarded_env([])
    ).and_return(relay)

    described_class.perform_now(session.id)
  end

  it "does not start a relay for a finished session" do
    session.update!(finished_at: Time.current, outcome: "exited")

    expect(TerminalRelay).not_to receive(:new)

    described_class.perform_now(session.id)
  end
end
