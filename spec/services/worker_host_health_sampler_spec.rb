require "rails_helper"

RSpec.describe WorkerHostHealthSampler do
  describe ".parse_meminfo" do
    it "extracts total, available, and used percentage" do
      metrics = described_class.parse_meminfo(<<~MEMINFO)
        MemTotal:       1000000 kB
        MemFree:         200000 kB
        MemAvailable:    250000 kB
      MEMINFO

      expect(metrics).to eq(
        total_bytes: 1_000_000.kilobytes,
        available_bytes: 250_000.kilobytes,
        used_percent: 75.0
      )
    end

    it "falls back to MemFree when MemAvailable is absent" do
      metrics = described_class.parse_meminfo(<<~MEMINFO)
        MemTotal:       1000000 kB
        MemFree:         200000 kB
      MEMINFO

      expect(metrics[:available_bytes]).to eq(200_000.kilobytes)
      expect(metrics[:used_percent]).to eq(80.0)
    end
  end

  describe ".parse_pressure" do
    it "extracts avg10 pressure values for some and full" do
      metrics = described_class.parse_pressure(<<~PRESSURE)
        some avg10=1.23 avg60=0.50 avg300=0.10 total=12345
        full avg10=0.07 avg60=0.03 avg300=0.01 total=456
      PRESSURE

      expect(metrics).to eq(some: 1.23, full: 0.07)
    end
  end

  describe ".parse_cpu_stat" do
    it "extracts aggregate idle and total jiffies" do
      snapshot = described_class.parse_cpu_stat("cpu  100 20 30 400 50 0 0 0 0 0\n")

      expect(snapshot.idle).to eq(450)
      expect(snapshot.total).to eq(600)
    end
  end

  describe ".sample" do
    it "returns partial metrics when host files are unavailable" do
      allow(File).to receive(:read).and_raise(Errno::ENOENT)
      allow(DataRootDiskUsage).to receive(:read).and_return(nil)

      metrics = described_class.sample(observed_at: Time.zone.parse("2026-07-31 12:00:00 UTC"))

      expect(metrics).to include(
        cpu_used_percent: nil,
        load_1m: nil,
        memory_used_percent: nil,
        data_root_used_percent: nil,
        cpu_pressure_some: nil,
        io_pressure_full: nil
      )
      expect(metrics[:raw_metrics]).to include(
        sampler: "worker_host_health_sampler",
        observed_at: "2026-07-31T12:00:00Z"
      )
    end

    it "uses the supplied data-root snapshot instead of reading df again" do
      snapshot = DataRootDiskUsage::Snapshot.new(
        path: "/data", filesystem: "/dev/pvc", total_bytes: 100.gigabytes,
        used_bytes: 60.gigabytes, available_bytes: 40.gigabytes, used_percent: 60,
        mounted_on: "/data", observed_at: Time.current
      )
      allow(File).to receive(:read).and_raise(Errno::ENOENT)
      expect(DataRootDiskUsage).not_to receive(:read)

      metrics = described_class.sample(data_root_snapshot: snapshot)

      expect(metrics).to include(
        data_root_used_percent: 60,
        data_root_available_bytes: 40.gigabytes,
        data_root_total_bytes: 100.gigabytes
      )
      expect(metrics[:raw_metrics]).to include(data_root_path: "/data", data_root_filesystem: "/dev/pvc")
    end
  end

  describe ".record!" do
    it "persists one sample row for each worker host observation" do
      allow(described_class).to receive(:sample).and_return(
        cpu_used_percent: 12.5,
        load_1m: 1.0,
        load_5m: 0.8,
        load_15m: 0.6,
        memory_used_percent: 70.0,
        memory_available_bytes: 3.gigabytes,
        memory_total_bytes: 10.gigabytes,
        data_root_used_percent: 40.0,
        data_root_available_bytes: 60.gigabytes,
        data_root_total_bytes: 100.gigabytes,
        cpu_pressure_some: 0.1,
        cpu_pressure_full: 0.0,
        io_pressure_some: 0.2,
        io_pressure_full: 0.0,
        raw_metrics: { "source" => "spec" }
      )
      observed_at = Time.zone.parse("2026-07-31 12:00:00 UTC")
      first = InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc", started_at: observed_at, last_heartbeat_at: observed_at)
      second = InstanceVersion.create!(hostname: "worker-b", role: "worker", version: "abc", started_at: observed_at, last_heartbeat_at: observed_at)

      described_class.record!(instance: first, observed_at: observed_at)
      described_class.record!(instance: second, observed_at: observed_at)

      expect(WorkerHostHealthSample.order(:hostname).pluck(:hostname, :role, :observed_at)).to eq([
        [ "worker-a", "worker", observed_at ],
        [ "worker-b", "worker", observed_at ]
      ])
      expect(WorkerHostHealthSample.first.cpu_used_percent).to eq(12.5)
    end
  end
end
