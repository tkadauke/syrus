require "rails_helper"

RSpec.describe PendingActions::SpawnChat do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:action) do
    chat_session.pending_actions.create!(
      action: "spawn_chat",
      payload: { "prompt" => "Investigate this", "batch_size" => 1 },
      requested_by: "agent"
    )
  end

  it "pre-opens a zero-hop coordination thread without delivering another message" do
    spawned = described_class.new(action).execute

    thread = ChatBridgeThread.sole
    expect(thread).to have_attributes(
      origin_chat_session_id: chat_session.id,
      target_chat_session_id: spawned.id,
      opened_by_user_id: user.id,
      max_hops: ChatBridgeThread::DEFAULT_MAX_HOPS,
      hop_count: 0,
      state: "open"
    )
    expect(action.reload.payload).to include(
      "spawned_chat_id" => spawned.id,
      "bridge_thread_id" => thread.id
    )
    expect(spawned.messages.pluck(:role)).to eq([ "user" ])
    expect(ChatWakeup.count).to eq(0)
  end
end
