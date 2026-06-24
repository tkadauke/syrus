require "rails_helper"

RSpec.describe ChatWakeupFireJob do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def create_wakeup(state: "pending")
    ChatWakeup.create!(
      chat_session: chat_session,
      user: user,
      prompt: "Check job #123 and report back.",
      fire_at: 1.minute.ago,
      state: state
    )
  end

  it "runs the wakeup turn and marks the wakeup fired" do
    wakeup = create_wakeup
    turn = instance_double(ChatSession::WakeupTurn, run: true)

    expect(ChatSession::WakeupTurn).to receive(:new).with(wakeup).and_return(turn)

    described_class.perform_now(wakeup.id)

    expect(wakeup.reload).to be_fired
  end

  it "skips cancelled wakeups" do
    wakeup = create_wakeup(state: "cancelled")

    expect(ChatSession::WakeupTurn).not_to receive(:new)

    described_class.perform_now(wakeup.id)

    expect(wakeup.reload).to be_cancelled
  end

  it "does not fire the same wakeup twice after it leaves pending" do
    wakeup = create_wakeup
    turn = instance_double(ChatSession::WakeupTurn, run: true)

    expect(ChatSession::WakeupTurn).to receive(:new).once.with(wakeup).and_return(turn)

    described_class.perform_now(wakeup.id)
    described_class.perform_now(wakeup.id)
  end
end
