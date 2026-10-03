require "rails_helper"

RSpec.describe InstanceVersion do
  def fixture(**overrides)
    InstanceVersion.create!({
      hostname: "syrus-web-abc",
      role: "web",
      version: "1234567",
      started_at: 1.minute.ago,
      last_heartbeat_at: 5.seconds.ago
    }.merge(overrides))
  end

  describe "#stale?" do
    it "is false for a fresh heartbeat" do
      expect(fixture(last_heartbeat_at: 10.seconds.ago)).not_to be_stale
    end

    it "is true when heartbeat is older than the threshold" do
      expect(fixture(last_heartbeat_at: 5.minutes.ago)).to be_stale
    end

    it "is false for a just-registered instance with no heartbeat yet" do
      expect(fixture(last_heartbeat_at: nil, started_at: 5.seconds.ago)).not_to be_stale
    end

    it "is true for an instance that registered but never heartbeated and has aged past threshold" do
      expect(fixture(last_heartbeat_at: nil, started_at: 10.minutes.ago)).to be_stale
    end

    it "is false once finalized" do
      sp = fixture(finished_at: 1.minute.ago, outcome: "shutdown")
      expect(sp).not_to be_stale
    end
  end

  it "defaults capability payloads to empty hashes" do
    instance = fixture(capabilities: nil, capability_diagnostics: nil)

    expect(instance.capabilities).to eq({})
    expect(instance.capability_diagnostics).to eq({})
  end

  describe ".fresh" do
    it "returns running rows whose last_heartbeat_at is within the threshold" do
      fresh = fixture(last_heartbeat_at: 10.seconds.ago)
      fixture(hostname: "syrus-web-stale", last_heartbeat_at: 10.minutes.ago)
      fixture(hostname: "syrus-web-done", finished_at: 30.seconds.ago, outcome: "shutdown")

      expect(InstanceVersion.fresh).to contain_exactly(fresh)
    end

    it "treats a recently-created row with no heartbeat as fresh" do
      newly = fixture(last_heartbeat_at: nil, started_at: 5.seconds.ago)

      expect(InstanceVersion.fresh).to include(newly)
    end
  end

  describe ".worker_queue_live?" do
    def solid_queue_process(queues:, last_heartbeat_at: Time.current)
      ensure_solid_queue_test_tables!
      SolidQueue::Process.create!(
        hostname: "worker-a",
        kind: "worker",
        last_heartbeat_at: last_heartbeat_at,
        metadata: { "queues" => queues },
        name: "worker-a:1",
        pid: 123,
        created_at: Time.current
      )
    end

    it "is true when a fresh Solid Queue worker advertises the queue" do
      solid_queue_process(queues: [ "resume-storage-a", "runs" ])

      expect(described_class.worker_queue_live?("resume-storage-a")).to eq(true)
    end

    it "supports comma-separated queue metadata" do
      solid_queue_process(queues: "resume-storage-a,runs")

      expect(described_class.worker_queue_live?("resume-storage-a")).to eq(true)
    end

    it "is false when only stale workers advertise the queue" do
      solid_queue_process(queues: [ "resume-storage-a" ], last_heartbeat_at: 10.minutes.ago)

      expect(described_class.worker_queue_live?("resume-storage-a")).to eq(false)
    end
  end

  describe "#seconds_since_heartbeat" do
    it "is nil when there's no heartbeat yet" do
      expect(fixture(last_heartbeat_at: nil).seconds_since_heartbeat).to be_nil
    end

    it "rounds to whole seconds" do
      sp = fixture(last_heartbeat_at: 7.4.seconds.ago)
      expect(sp.seconds_since_heartbeat).to be_between(6, 8)
    end
  end
end
