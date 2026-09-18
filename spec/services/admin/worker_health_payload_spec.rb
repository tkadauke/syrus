require "rails_helper"

RSpec.describe Admin::WorkerHealthPayload do
  def instance(hostname:, observed_at: Time.current)
    InstanceVersion.create!(
      hostname: hostname,
      role: "worker",
      version: "abc123",
      started_at: observed_at - 5.minutes,
      last_heartbeat_at: observed_at
    )
  end

  def sample(hostname:, worker_storage_key:, observed_at:, cpu:)
    WorkerHostHealthSample.create!(
      hostname: hostname,
      worker_storage_key: worker_storage_key,
      role: "worker",
      version: "abc123",
      observed_at: observed_at,
      cpu_used_percent: cpu,
      memory_used_percent: 40.0,
      data_root_used_percent: 30.0
    )
  end

  it "groups restarted pod hostnames into one durable worker history row" do
    now = Time.zone.parse("2026-09-18 16:00:00 UTC")
    travel_to(now) do
      instance(hostname: "syrus-worker-new", observed_at: now)
      sample(hostname: "syrus-worker-old", worker_storage_key: "storage-a", observed_at: now - 20.minutes, cpu: 20.0)
      sample(hostname: "syrus-worker-new", worker_storage_key: "storage-a", observed_at: now - 1.minute, cpu: 65.0)

      payload = described_class.new(since: (now - 1.hour).iso8601, until_time: now.iso8601).as_json

      expect(payload.fetch(:current).pluck(:hostname, :worker_storage_key)).to eq([
        [ "syrus-worker-new", "storage-a" ]
      ])

      host = payload.fetch(:hosts).sole
      expect(host).to include(
        key: "storage-a",
        worker_storage_key: "storage-a",
        hostname: "syrus-worker-new",
        status: "current"
      )
      expect(host.fetch(:recent_samples).pluck(:hostname)).to eq([ "syrus-worker-new", "syrus-worker-old" ])
      expect(host.dig(:windows, "1h", :sample_count)).to eq(2)
    end
  end

  it "falls back to hostname for legacy rows without a worker storage key" do
    now = Time.zone.parse("2026-09-18 16:00:00 UTC")
    travel_to(now) do
      sample(hostname: "legacy-worker", worker_storage_key: nil, observed_at: now - 1.minute, cpu: 35.0)

      host = described_class.new(since: (now - 1.hour).iso8601, until_time: now.iso8601).as_json.fetch(:hosts).sole

      expect(host).to include(key: "legacy-worker", worker_storage_key: "legacy-worker", hostname: "legacy-worker")
    end
  end
end
