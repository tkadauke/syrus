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

  it "skips cleanly when the SolidQueue tables are unreachable" do
    sp = fixture(hostname: "any-pod")
    allow_any_instance_of(described_class)
      .to receive(:live_solid_queue_hostnames)
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
    fixture(hostname: "dead-pod-xyz", workdir: chat.workspace_root.to_s, started_at: 15.seconds.ago)
    stub_live_hosts("live-pod")

    described_class.perform_now

    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ]
    )
  end
end
