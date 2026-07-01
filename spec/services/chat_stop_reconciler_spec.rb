require "rails_helper"

RSpec.describe ChatStopReconciler do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }

  it "promotes the next queued message after a stopped turn is finalized" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler", stop_requested_at: 10.seconds.ago)
    chat.messages.create!(role: "user", content: { "text" => "Stop this" }, created_at: 20.seconds.ago)
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Follow up after stop" })

    expect {
      described_class.reconcile!(chat_session: chat, stop_requested_before: Time.current)
    }.to have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

    expect(chat.reload.stop_requested_at).to be_nil
    expect(queued_message.reload.delivered_at).to be_present
    expect(chat).to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ],
      [ "user", { "text" => "Follow up after stop" } ]
    )
  end

  it "leaves queued messages pending while a stopped turn still has a live process" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-live", stop_requested_at: 10.seconds.ago)
    chat.messages.create!(role: "user", content: { "text" => "Stop this" }, created_at: 20.seconds.ago)
    queued_message = chat.chat_queued_messages.create!(content: { "text" => "Wait until process exit" })
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: 15.seconds.ago
    )

    expect {
      described_class.reconcile!(chat_session: chat, stop_requested_before: Time.current)
    }.not_to have_enqueued_job(ChatTurnJob)

    expect(chat.reload.stop_requested_at).to be_present
    expect(queued_message.reload.delivered_at).to be_nil
  end
end
