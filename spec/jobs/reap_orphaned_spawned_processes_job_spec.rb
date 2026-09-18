require "rails_helper"
require "socket"

RSpec.describe ReapOrphanedSpawnedProcessesJob do
  def fixture(**overrides)
    SpawnedProcess.create!({
      kind: "agent",
      command: "claude --print",
      hostname: "some-pod-abc",
      started_at: 30.minutes.ago,
      last_chunk_at: 20.minutes.ago,
      pid: 12_345
    }.merge(overrides))
  end

  # SolidQueue tables aren't reachable from the test connection
  # (single-DB), so we stub the private live-hosts method on each
  # job instance. Each example sets up which hostnames are "live".
  def stub_live_hosts(*hostnames)
    allow_any_instance_of(described_class)
      .to receive(:live_solid_queue_hostnames)
      .and_return(Set.new(hostnames))
    allow_any_instance_of(described_class)
      .to receive(:live_instance_version_hostnames)
      .and_return(Set.new)
  end

  def stub_fresh_worker_start(hostname, started_at)
    allow_any_instance_of(described_class)
      .to receive(:fresh_worker_starts_by_host)
      .and_return({ hostname => started_at })
  end

  it "finalizes rows whose hostname is not in the live SolidQueue process set" do
    dead = fixture(hostname: "dead-pod-xyz")
    stub_live_hosts("some-other-live-pod")

    described_class.perform_now

    dead.reload
    expect(dead).to be_finished
    expect(dead.outcome).to eq("orphaned")
  end

  it "leaves rows whose hostname IS in the live set alone" do
    live = fixture(hostname: "live-pod-abc")
    stub_live_hosts("live-pod-abc", "some-other-live-pod")

    described_class.perform_now

    live.reload
    expect(live).to be_running
  end

  it "finalizes old pidless rows even when their hostname is still live" do
    pidless = fixture(hostname: "live-pod-abc", pid: nil, started_at: 2.minutes.ago)
    stub_live_hosts("live-pod-abc")

    described_class.perform_now

    pidless.reload
    expect(pidless).to be_finished
    expect(pidless.outcome).to eq("orphaned")
  end

  it "finalizes rows from a previous worker process on a live hostname" do
    old = fixture(hostname: "live-pod-abc", pid: 1234, started_at: 10.minutes.ago)
    fresh_started_at = 5.minutes.ago
    stub_live_hosts("live-pod-abc")
    stub_fresh_worker_start("live-pod-abc", fresh_started_at)

    described_class.perform_now

    old.reload
    expect(old).to be_finished
    expect(old.outcome).to eq("orphaned")
  end

  it "leaves rows from the current worker process alone" do
    current = fixture(hostname: "live-pod-abc", pid: 1234, started_at: 1.minute.ago)
    fresh_started_at = 5.minutes.ago
    stub_live_hosts("live-pod-abc")
    stub_fresh_worker_start("live-pod-abc", fresh_started_at)

    described_class.perform_now

    current.reload
    expect(current).to be_running
  end

  it "leaves preview rows whose hostname has a fresh InstanceVersion heartbeat alone" do
    preview = fixture(kind: "preview", hostname: "syrus-preview-abc")
    allow_any_instance_of(described_class)
      .to receive(:live_solid_queue_hostnames)
      .and_return(Set.new([ "worker-pod" ]))
    allow_any_instance_of(described_class)
      .to receive(:live_instance_version_hostnames)
      .and_return(Set.new([ "syrus-preview-abc" ]))

    described_class.perform_now

    preview.reload
    expect(preview).to be_running
  end

  it "skips cleanly when the SolidQueue tables are unreachable" do
    sp = fixture(hostname: "any-pod")
    allow_any_instance_of(described_class)
      .to receive(:live_solid_queue_hostnames)
      .and_return(nil)
    allow_any_instance_of(described_class)
      .to receive(:live_instance_version_hostnames)
      .and_return(nil)

    expect { described_class.perform_now }.not_to raise_error

    sp.reload
    expect(sp).to be_running
  end

  it "does not touch already-finished rows on dead hosts (lost race)" do
    sp = fixture(hostname: "dead-pod-xyz",
                 finished_at: 1.second.ago,
                 outcome: "succeeded",
                 exit_status: 0)
    stub_live_hosts("live-pod")

    described_class.perform_now

    sp.reload
    expect(sp.outcome).to eq("succeeded") # conditional update_all returned 0
  end

  it "reconciles stopped chat sessions for cross-host orphaned agent processes" do
    user = Factories.user(claude_oauth_token: "oat-test")
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-reaper", stop_requested_at: 10.seconds.ago)
    chat.messages.create!(role: "user", content: { "text" => "Stop this" }, created_at: 20.seconds.ago)
    chat.messages.create!(
      role: "tool_use",
      tool_name: "syrus-chat-sidecar.admin_overview",
      tool_use_id: "call_reaper",
      content: {
        "type" => "tool_use",
        "id" => "call_reaper",
        "name" => "syrus-chat-sidecar.admin_overview",
        "input" => {}
      },
      created_at: 19.seconds.ago
    )
    fixture(hostname: "dead-pod-xyz", workdir: chat.workspace_root.to_s, started_at: 15.seconds.ago)
    stub_live_hosts("live-pod")

    described_class.perform_now

    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ]
    )
    tool_result = chat.messages.find_by!(role: "tool_result", tool_use_id: "call_reaper")
    expect(tool_result.content).to include(
      "type" => "tool_result",
      "tool_use_id" => "call_reaper",
      "is_error" => true
    )
    expect(tool_result.content.dig("content", 0, "text")).to eq("Cancelled by operator before this tool returned.")
  end

  it "schedules an auto-retry for orphaned chat agent turns when there was no stop request" do
    user = Factories.user(claude_oauth_token: "oat-test")
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-reaper-failed")
    message = chat.messages.create!(role: "user", content: { "text" => "This turn crashed" }, created_at: 20.seconds.ago)
    fixture(hostname: "dead-pod-xyz", workdir: chat.workspace_root.to_s, started_at: 15.seconds.ago)
    stub_live_hosts("live-pod")

    expect {
      described_class.perform_now
    }.to change(ChatTurnAutoRetryAttempt, :count).by(1)

    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).to be_turn_in_flight
    expect(ChatTurnAutoRetryAttempt.last).to have_attributes(
      chat_session: chat,
      root_user_message: message,
      user_message: message,
      attempt_number: 1
    )
    expect(chat.messages.order(:created_at).pluck(:role, :content)).not_to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  end

  it "marks stale unanswered chat turns as failed when no spawned process exists" do
    user = Factories.user(claude_oauth_token: "oat-test")
    chat = ChatSession.create!(user: user, workspace_path: "/tmp/chat-reaper-stale")
    chat.messages.create!(
      role: "user",
      content: { "text" => "This turn vanished before starting an agent process" },
      created_at: 3.hours.ago
    )
    stub_live_hosts("live-pod")

    described_class.perform_now

    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Agent turn failed." } ]
    )
  end
end
