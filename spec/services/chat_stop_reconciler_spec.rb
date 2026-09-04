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
      started_at: 15.seconds.ago,
      pid: 1234
    )

    expect {
      described_class.reconcile!(chat_session: chat, stop_requested_before: Time.current)
    }.not_to have_enqueued_job(ChatTurnJob)

    expect(chat.reload.stop_requested_at).to be_present
    expect(queued_message.reload.delivered_at).to be_nil
  end

  it "marks an orphaned chat agent turn as failed even without a stop request" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-orphaned")
    chat.messages.create!(role: "user", content: { "text" => "This turn crashed" }, created_at: 20.seconds.ago)
    spawned_process = SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "dead-worker",
      started_at: 15.seconds.ago,
      finished_at: Time.current,
      outcome: "orphaned"
    )

    expect {
      described_class.reconcile_spawned_process!(spawned_process)
    }.not_to have_enqueued_job(ChatTurnJob)

    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  end

  it "marks a failed chat agent process as failed and closes dangling tool calls" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-failed-process")
    chat.messages.create!(role: "user", content: { "text" => "This turn crashed" }, created_at: 20.seconds.ago)
    chat.messages.create!(
      role: "tool_use",
      tool_use_id: "call_crashed_tool",
      tool_name: "Bash",
      content: {
        "type" => "tool_use",
        "id" => "call_crashed_tool",
        "name" => "Bash",
        "input" => { "command" => "sleep 10" }
      },
      created_at: 10.seconds.ago
    )
    spawned_process = SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "worker-1",
      started_at: 15.seconds.ago,
      finished_at: Time.current,
      outcome: "failed"
    )

    expect(described_class.reconcile_spawned_process!(spawned_process)).to eq(true)

    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
    tool_result = chat.messages.find_by!(role: "tool_result", tool_use_id: "call_crashed_tool")
    expect(tool_result.content.dig("content", 0, "text")).to eq("Agent turn failed before this tool returned.")
  end

  it "does not mark normal completed agent processes as failed while ChatTurnJob finishes" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-success")
    chat.messages.create!(role: "user", content: { "text" => "This turn is still flushing" }, created_at: 20.seconds.ago)
    spawned_process = SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat.workspace_root.to_s,
      hostname: "live-worker",
      started_at: 15.seconds.ago,
      finished_at: Time.current,
      outcome: "succeeded",
      exit_status: 0
    )

    expect(described_class.reconcile_spawned_process!(spawned_process)).to eq(false)

    expect(chat.reload).to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).not_to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  end

  it "marks stale unanswered chat turns as failed even when no spawned process was recorded" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-stale")
    chat.messages.create!(
      role: "user",
      content: { "text" => "This turn disappeared before process registration" },
      created_at: 3.hours.ago
    )

    expect(described_class.reconcile!(chat_session: chat, stale_before: 2.hours.ago)).to eq(true)

    expect(chat.reload).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  end

  it "leaves stale-looking chat turns alone while their ChatTurnJob is still unfinished" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!

    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-stale-pending")
    message = chat.messages.create!(
      role: "user",
      content: { "text" => "This turn is waiting for its queued job" },
      created_at: 3.hours.ago
    )
    queue_job = SolidQueue::Job.create!(
      class_name: "ChatTurnJob",
      queue_name: "chat",
      priority: 0,
      arguments: { "arguments" => [ chat.id, message.id ] },
      created_at: 3.hours.ago,
      updated_at: 3.hours.ago
    )

    expect(described_class.reconcile!(chat_session: chat, stale_before: 2.hours.ago)).to eq(false)

    expect(chat.reload).to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).not_to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "does not let a failed ChatTurnJob row suppress stale-turn recovery" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!

    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-stale-failed-job")
    message = chat.messages.create!(
      role: "user",
      content: { "text" => "This turn failed before writing a terminal message" },
      created_at: 3.hours.ago
    )
    queue_job = SolidQueue::Job.create!(
      class_name: "ChatTurnJob",
      queue_name: "chat",
      priority: 0,
      arguments: { "arguments" => [ chat.id, message.id ] },
      created_at: 3.hours.ago,
      updated_at: 3.hours.ago
    )
    SolidQueue::ReadyExecution.where(job_id: queue_job.id).delete_all
    SolidQueue::FailedExecution.create!(
      job: queue_job,
      error: { "exception_class" => "SolidQueue::Processes::ProcessPrunedError" },
      created_at: 2.hours.ago
    )

    expect(described_class.reconcile!(chat_session: chat, stale_before: 2.hours.ago)).to eq(true)

    expect(chat.reload).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "does not mark fresh unanswered chat turns as failed" do
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-stop-reconciler-fresh")
    chat.messages.create!(
      role: "user",
      content: { "text" => "This turn has not had enough time to complete" },
      created_at: 30.minutes.ago
    )

    expect(described_class.reconcile!(chat_session: chat, stale_before: 2.hours.ago)).to eq(false)

    expect(chat.reload).to be_turn_in_flight
    expect(chat.messages.order(:created_at, :id).pluck(:role, :content)).not_to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  end
end
