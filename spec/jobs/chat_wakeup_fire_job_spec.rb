require "rails_helper"

RSpec.describe ChatWakeupFireJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def create_wakeup(state: "pending")
    ChatWakeup.create!(
      chat_session: chat_session,
      user: user,
      prompt: "Check JOB-123 and report back.",
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

  it "locks the chat before the pending wakeup" do
    wakeup = create_wakeup
    turn = instance_double(ChatSession::WakeupTurn, run: true)
    allow(ChatSession::WakeupTurn).to receive(:new).and_return(turn)

    expect(ChatSession).to receive(:lock).ordered.and_call_original
    expect(ChatWakeup).to receive(:pending).ordered.and_call_original

    described_class.perform_now(wakeup.id)
  end

  it "cancels a still-pending wakeup when its chat was soft-deleted" do
    wakeup = create_wakeup
    chat_session.update_column(:deleted_at, Time.current)

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

  it "resumes the intended chat exactly once when the fire job is retried" do
    other_chat = ChatSession.create!(user: user)
    wakeup = create_wakeup

    expect {
      described_class.perform_now(wakeup.id)
      described_class.perform_now(wakeup.id)
    }.to change { chat_session.messages.count }.by(1)
      .and have_enqueued_job(ChatTurnJob).exactly(:once)

    message = chat_session.messages.order(:id).last
    expect(message.content).to include("requested_by" => "wakeup", "wakeup_id" => wakeup.id)
    expect(other_chat.messages).to be_empty
    expect(wakeup.reload).to be_fired
  end
end
