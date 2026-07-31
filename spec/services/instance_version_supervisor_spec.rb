require "rails_helper"

RSpec.describe InstanceVersionSupervisor do
  describe ".heartbeat" do
    it "bumps last_heartbeat_at on the supplied instance" do
      sp = InstanceVersion.create!(hostname: "syrus-web-abc", role: "web", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 30.seconds.ago)

      described_class.heartbeat(sp)

      expect(sp.reload.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end

    it "stamps the worker's data-root usage on each heartbeat (worker role only)" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      snapshot = DataRootDiskUsage::Snapshot.new(
        path: "/syrus-home/.syrus", filesystem: "/dev/x", total_bytes: 100.gigabytes,
        used_bytes: 94.gigabytes, available_bytes: 6.gigabytes, used_percent: 94,
        mounted_on: "/syrus-home", observed_at: Time.current
      )
      allow(DataRootDiskUsage).to receive(:read).and_return(snapshot)
      allow(WorkerHostHealthSampler).to receive(:record!)
      sp = InstanceVersion.create!(hostname: "syrus-worker-1", role: "worker", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 30.seconds.ago)

      described_class.heartbeat(sp)

      sp.reload
      expect(sp.data_root_used_percent).to eq(94)
      expect(sp.data_root_available_bytes).to eq(6.gigabytes)
      expect(sp.data_root_alert_level).to eq(:warning)
      expect(WorkerHostHealthSampler).to have_received(:record!).with(instance: sp, observed_at: kind_of(Time), data_root_snapshot: snapshot)
    end

    it "does not measure disk on a web pod" do
      allow(SyrusVersion).to receive(:role).and_return("web")
      expect(DataRootDiskUsage).not_to receive(:read)
      expect(WorkerHostHealthSampler).not_to receive(:record!)
      sp = InstanceVersion.create!(hostname: "syrus-web-1", role: "web", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 30.seconds.ago)

      described_class.heartbeat(sp)

      expect(sp.reload.data_root_used_percent).to be_nil
    end

    it "is a no-op when the row has already been finalized" do
      sp = InstanceVersion.create!(hostname: "syrus-web-abc", role: "web", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 30.seconds.ago,
                                    finished_at: 5.seconds.ago, outcome: "shutdown")
      before_heartbeat = sp.last_heartbeat_at

      expect(WorkerHostHealthSampler).not_to receive(:record!)

      described_class.heartbeat(sp)

      expect(sp.reload.last_heartbeat_at).to be_within(0.001).of(before_heartbeat)
    end

    it "keeps the heartbeat alive when historical sampling fails" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      allow(DataRootDiskUsage).to receive(:read).and_return(nil)
      allow(WorkerHostHealthSampler).to receive(:record!).and_raise(StandardError, "sample failed")
      sp = InstanceVersion.create!(hostname: "syrus-worker-2", role: "worker", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 30.seconds.ago)

      expect { described_class.heartbeat(sp) }.not_to raise_error
      expect(sp.reload.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe ".finalize" do
    it "stamps finished_at and outcome on a running row" do
      sp = InstanceVersion.create!(hostname: "syrus-web-abc", role: "web", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 5.seconds.ago)

      described_class.finalize(sp, outcome: "shutdown")

      sp.reload
      expect(sp).to be_finished
      expect(sp.outcome).to eq("shutdown")
    end

    it "is idempotent — calling twice doesn't move finished_at" do
      sp = InstanceVersion.create!(hostname: "syrus-web-abc", role: "web", version: "abc",
                                    started_at: 1.minute.ago, last_heartbeat_at: 5.seconds.ago)
      described_class.finalize(sp, outcome: "shutdown")
      first_finished_at = sp.reload.finished_at

      described_class.finalize(sp, outcome: "shutdown")

      expect(sp.reload.finished_at).to eq(first_finished_at)
    end
  end

  describe ".ensure_running" do
    after { described_class.reset_for_tests! }

    it "is a no-op in the test environment" do
      expect { described_class.ensure_running }.not_to raise_error
      expect(InstanceVersion.count).to eq(0)
    end

    it "does not fail boot when instance registration hits a lock timeout" do
      thread = instance_double(Thread, alive?: true, kill: nil)
      allow(described_class).to receive(:disabled?).and_return(false)
      allow(described_class).to receive(:register_instance!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
      allow(described_class).to receive(:spawn_heartbeat_thread).and_return(thread)
      allow(described_class).to receive(:install_at_exit_hook).and_return(true)

      expect { described_class.ensure_running }.not_to raise_error
      expect(InstanceVersion.count).to eq(0)
    end
  end
end
