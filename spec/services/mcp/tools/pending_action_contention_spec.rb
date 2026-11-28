require "rails_helper"

RSpec.describe Mcp::Tools::ProposalToolSupport do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:message) do
    chat_session.messages.create!(
      role: "assistant",
      content: { "type" => "tool_use", "id" => "tool-call-1", "name" => "test_action", "input" => {} }
    )
  end
  let(:context) { { chat_session: chat_session, current_message: message } }
  let(:attributes) { { action: "cancel_job", payload: { "job_id" => 123 }, requested_by: "agent" } }

  def create_pending_action
    harness.send(:create_pending_action_for_current_message!, context, chat_session, **attributes)
  end

  let(:harness) do
    Class.new do
      extend Mcp::Tools::ProposalToolSupport
    end
  end

  it "retries an insert lock conflict and creates one anchored pending action" do
    attempts = 0
    allow(chat_session.pending_actions).to receive(:create!).and_wrap_original do |original, **attrs|
      attempts += 1
      raise ActiveRecord::Deadlocked, "deadlock" if attempts == 1

      original.call(**attrs)
    end

    pending_action = create_pending_action

    expect(attempts).to eq(2)
    expect(chat_session.pending_actions.reload).to contain_exactly(pending_action)
    expect(message.reload.pending_action).to eq(pending_action)
  end

  it "rolls back the insert when anchoring hits a lock conflict, then retries without an orphan" do
    attempts = 0
    allow(message).to receive(:update_columns).and_wrap_original do |original, attrs|
      attempts += 1
      raise ActiveRecord::LockWaitTimeout, "lock wait" if attempts == 1

      original.call(attrs)
    end

    pending_action = create_pending_action

    expect(attempts).to eq(2)
    expect(chat_session.pending_actions.reload).to contain_exactly(pending_action)
    expect(message.reload.pending_action).to eq(pending_action)
  end

  it "reconciles an ambiguous committed outcome from the current message anchor" do
    existing = chat_session.pending_actions.create!(**attributes)
    message.update_columns(pending_action_id: existing.id)

    expect(chat_session.pending_actions).not_to receive(:create!)

    expect(create_pending_action).to eq(existing)
  end

  it "creates a fresh request when the anchored pending action was already resolved" do
    existing = chat_session.pending_actions.create!(**attributes)
    existing.update_columns(state: "rejected")
    message.update_columns(pending_action_id: existing.id)

    pending_action = create_pending_action

    expect(pending_action).not_to eq(existing)
    expect(pending_action).to be_persisted
    expect(message.reload.pending_action).to eq(pending_action)
  end

  it "does not retry non-transient failures" do
    allow(chat_session.pending_actions).to receive(:create!).and_raise(ArgumentError, "bad application state")

    expect { create_pending_action }.to raise_error(ArgumentError, "bad application state")
    expect(chat_session.pending_actions).to have_received(:create!).once
  end
end
