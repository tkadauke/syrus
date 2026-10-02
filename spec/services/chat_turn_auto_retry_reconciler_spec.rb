require "rails_helper"

RSpec.describe ChatTurnAutoRetryReconciler do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }

  def create_stuck_chat(message_created_at: 2.minutes.ago, last_message_at: 2.minutes.ago, workspace_path: "/tmp/chat-turn-auto-retry-#{SecureRandom.hex(4)}")
    chat = ChatSession.create!(
      user: user,
      workspace_path: workspace_path,
      last_message_at: last_message_at,
      turn_in_flight: true
    )
    message = chat.messages.create!(
      role: "user",
      content: { "text" => "Please continue the work." },
      sender_user_id: user.id,
      created_at: message_created_at
    )
    [ chat, message ]
  end

  it "schedules a first retry for a confirmed-dead turn after the initial backoff" do
    chat, message = create_stuck_chat
    now = Time.current

    expect {
      travel_to(now) { described_class.sweep! }
    }.to change(ChatTurnAutoRetryAttempt, :count).by(1)

    attempt = ChatTurnAutoRetryAttempt.last
    expect(attempt).to have_attributes(
      chat_session: chat,
      root_user_message: message,
      user_message: message,
      attempt_number: 1
    )
    expect(attempt.scheduled_at.to_i).to eq((now + 5.minutes).to_i)
    expect(chat.reload).to be_turn_in_flight
  end

  it "performs due retries by waking the chat and enqueuing the original user message" do
    chat, message = create_stuck_chat
    attempt = ChatTurnAutoRetryAttempt.create!(
      chat_session: chat,
      root_user_message: message,
      user_message: message,
      attempt_number: 1,
      scheduled_at: 1.minute.ago
    )

    user_message_count = chat.messages.where(role: "user", content: message.content).count
    retry_status_count = chat.messages.where(role: "system").count { |chat_message| chat_message.content["source"] == "chat_turn_retry" }

    expect {
      described_class.sweep!
    }.to have_enqueued_job(ChatTurnJob).with(chat.id, message.id).on_queue("chat")

    expect(chat.messages.where(role: "user", content: message.content).count).to eq(user_message_count)
    expect(chat.messages.where(role: "system").count { |chat_message| chat_message.content["source"] == "chat_turn_retry" }).to eq(retry_status_count + 1)

    status_message = attempt.reload.retry_message
    expect(attempt.performed_at).to be_present
    expect(status_message).to have_attributes(
      chat_session: chat,
      role: "system",
      content: hash_including(
        "text" => "Retrying the previous assistant turn now.",
        "source" => "chat_turn_retry",
        "root_user_message_id" => message.id,
        "user_message_id" => message.id,
        "attempt_number" => 1
      )
    )
    expect(chat.reload).to be_turn_in_flight
  end

  it "performs a scheduled retry immediately before its automatic retry time without replaying the user message" do
    chat, message = create_stuck_chat
    now = Time.current
    attempt = ChatTurnAutoRetryAttempt.create!(
      chat_session: chat,
      root_user_message: message,
      user_message: message,
      attempt_number: 1,
      scheduled_at: now + 5.minutes
    )

    result = nil
    user_message_count = chat.messages.where(role: "user", content: message.content).count
    retry_status_count = chat.messages.where(role: "system").count { |chat_message| chat_message.content["source"] == "chat_turn_retry" }

    expect {
      travel_to(now) { result = described_class.perform_now!(chat) }
    }.to have_enqueued_job(ChatTurnJob).with(chat.id, message.id).on_queue("chat")

    expect(chat.messages.where(role: "user", content: message.content).count).to eq(user_message_count)
    expect(chat.messages.where(role: "system").count { |chat_message| chat_message.content["source"] == "chat_turn_retry" }).to eq(retry_status_count + 1)

    status_message = attempt.reload.retry_message
    expect(result).to be_performed
    expect(attempt.performed_at.to_i).to eq(now.to_i)
    expect(status_message).to have_attributes(
      chat_session: chat,
      role: "system",
      content: hash_including(
        "text" => "Retrying the previous assistant turn now.",
        "source" => "chat_turn_retry",
        "root_user_message_id" => message.id,
        "user_message_id" => message.id,
        "attempt_number" => 1
      )
    )
  end

  it "does not schedule a retry while the original agent process is still live" do
    chat, _message = create_stuck_chat
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: 90.seconds.ago,
      pid: 1234
    )

    expect {
      described_class.sweep!
    }.not_to change(ChatTurnAutoRetryAttempt, :count)

    expect(chat.reload).to be_turn_in_flight
  end

  it "does not schedule a retry while the original ChatTurnJob is still pending" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!

    chat, message = create_stuck_chat
    queue_job = SolidQueue::Job.create!(
      class_name: "ChatTurnJob",
      queue_name: "chat",
      priority: 0,
      arguments: { "arguments" => [ chat.id, message.id ] },
      created_at: 2.minutes.ago,
      updated_at: 2.minutes.ago
    )
    SolidQueue::ReadyExecution.create!(job: queue_job, queue_name: "chat", priority: 0, created_at: 2.minutes.ago)

    expect {
      described_class.sweep!
    }.not_to change(ChatTurnAutoRetryAttempt, :count)

    expect(chat.reload).to be_turn_in_flight
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "uses the shared retry budget and exponential backoff across retry status messages" do
    chat, root_message = create_stuck_chat(message_created_at: 40.minutes.ago)
    retry_status_message = chat.messages.create!(
      role: "system",
      content: { "text" => "Retrying the previous assistant turn now.", "source" => "chat_turn_retry" },
      created_at: 30.minutes.ago
    )
    ChatTurnAutoRetryAttempt.create!(
      chat_session: chat,
      root_user_message: root_message,
      user_message: root_message,
      retry_message: retry_status_message,
      attempt_number: 1,
      scheduled_at: 25.minutes.ago,
      performed_at: 20.minutes.ago
    )
    chat.update!(last_message_at: 2.minutes.ago, turn_in_flight: true)
    now = Time.current

    travel_to(now) { described_class.sweep! }

    attempt = ChatTurnAutoRetryAttempt.order(:attempt_number).last
    expect(attempt).to have_attributes(
      root_user_message: root_message,
      user_message: root_message,
      attempt_number: 2
    )
    expect(attempt.scheduled_at.to_i).to eq((now + 20.minutes).to_i)
  end

  it "exhausts the budget once and posts the terminal failure message" do
    chat, root_message = create_stuck_chat

    ChatTurnAutoRetryAttempt::MAX_ATTEMPTS.times do |index|
      retry_status_message = chat.messages.create!(
        role: "system",
        content: { "text" => "Retrying the previous assistant turn now.", "source" => "chat_turn_retry" },
        created_at: (20 - index).minutes.ago
      )
      ChatTurnAutoRetryAttempt.create!(
        chat_session: chat,
        root_user_message: root_message,
        user_message: root_message,
        retry_message: retry_status_message,
        attempt_number: index + 1,
        scheduled_at: (19 - index).minutes.ago,
        performed_at: (18 - index).minutes.ago
      )
    end
    chat.update!(last_message_at: 2.minutes.ago, turn_in_flight: true)

    expect {
      described_class.sweep!
      described_class.sweep!
    }.to change {
      chat.messages.where(role: "system", content: { "text" => "Agent turn failed." }).count
    }.by(1)

    expect(chat.reload).not_to be_turn_in_flight
    expect(ChatTurnAutoRetryAttempt.where(root_user_message: root_message).where.not(exhausted_at: nil).count).to eq(1)
  end
end
