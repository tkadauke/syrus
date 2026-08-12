require "rails_helper"

RSpec.describe WorkerHostHealthSampleJob do
  describe "#perform" do
    it "does nothing on a non-worker process" do
      allow(SyrusVersion).to receive(:role).and_return("web")

      expect { described_class.perform_now }.not_to change(WorkerHostHealthSample, :count)
      expect(InstanceVersion.count).to eq(0)
    end

    it "records a sample for the current worker instance when one already exists" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      allow(SyrusVersion).to receive(:hostname).and_return("syrus-worker-1")
      allow(SyrusVersion).to receive(:current).and_return("sha123")
      instance = InstanceVersion.create!(hostname: "syrus-worker-1", role: "worker", version: "sha123",
                                          started_at: 1.minute.ago, last_heartbeat_at: 1.minute.ago)
      allow(WorkerHostHealthSampler).to receive(:record!)

      described_class.perform_now

      expect(WorkerHostHealthSampler).to have_received(:record!).with(instance: instance)
      expect(InstanceVersion.count).to eq(1)
    end

    it "self-heals by creating the InstanceVersion row when registration never happened" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      allow(SyrusVersion).to receive(:hostname).and_return("syrus-worker-2")
      allow(SyrusVersion).to receive(:current).and_return("sha456")
      allow(WorkerHostHealthSampler).to receive(:record!)

      expect { described_class.perform_now }.to change(InstanceVersion, :count).by(1)

      created = InstanceVersion.find_by(hostname: "syrus-worker-2", role: "worker")
      expect(created.version).to eq("sha456")
      expect(WorkerHostHealthSampler).to have_received(:record!).with(instance: created)
    end

    it "does not raise when sampling fails" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      allow(SyrusVersion).to receive(:hostname).and_return("syrus-worker-3")
      allow(SyrusVersion).to receive(:current).and_return("sha789")
      allow(WorkerHostHealthSampler).to receive(:record!).and_raise(StandardError, "sample failed")

      expect { described_class.perform_now }.not_to raise_error
    end

    it "actually persists a WorkerHostHealthSample row end to end" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      allow(SyrusVersion).to receive(:hostname).and_return("syrus-worker-4")
      allow(SyrusVersion).to receive(:current).and_return("shaabc")
      allow(WorkerHostHealthSampler).to receive(:sample).and_return(
        cpu_used_percent: 10.0, load_1m: 0.1, load_5m: 0.1, load_15m: 0.1,
        memory_used_percent: 20.0, memory_available_bytes: 1.gigabyte, memory_total_bytes: 2.gigabytes,
        data_root_used_percent: 5.0, data_root_available_bytes: 1.gigabyte, data_root_total_bytes: 2.gigabytes,
        cpu_pressure_some: 0.0, cpu_pressure_full: 0.0, io_pressure_some: 0.0, io_pressure_full: 0.0,
        raw_metrics: {}
      )

      expect { described_class.perform_now }.to change(WorkerHostHealthSample, :count).by(1)
      expect(WorkerHostHealthSample.last.hostname).to eq("syrus-worker-4")
    end
  end
end
