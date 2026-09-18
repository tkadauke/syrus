require "rails_helper"

RSpec.describe Metrics::WorkerSource do
  subject(:source) { described_class.new }

  def sample(hostname:, role: "worker", observed_at: Time.current, **attrs)
    WorkerHostHealthSample.create!(
      hostname: hostname, role: role, version: "abc123", observed_at: observed_at, **attrs
    )
  end

  describe "#worker_cpu_percentages" do
    it "returns the latest sample's CPU percentage per hostname" do
      sample(hostname: "worker-a", cpu_used_percent: 10.0, observed_at: 10.minutes.ago) # stale
      sample(hostname: "worker-a", cpu_used_percent: 87.5)
      sample(hostname: "worker-b", cpu_used_percent: 12.0)

      expect(source.worker_cpu_percentages).to eq("worker-a" => 87.5, "worker-b" => 12.0)
    end

    it "excludes hosts with no recent sample" do
      sample(hostname: "worker-a", cpu_used_percent: 10.0, observed_at: 10.minutes.ago)

      expect(source.worker_cpu_percentages).to eq({})
    end

    it "ignores non-worker roles" do
      sample(hostname: "web-a", role: "web", cpu_used_percent: 50.0)

      expect(source.worker_cpu_percentages).to eq({})
    end
  end

  describe "#worker_memory_percentages" do
    it "returns the latest sample's memory percentage per hostname" do
      sample(hostname: "worker-a", memory_used_percent: 42.0)
      sample(hostname: "worker-b", memory_used_percent: 30.0)

      expect(source.worker_memory_percentages).to eq("worker-a" => 42.0, "worker-b" => 30.0)
    end
  end

  describe "#worker_disk_percentages" do
    it "returns the latest sample's data-root disk percentage per hostname" do
      sample(hostname: "worker-a", data_root_used_percent: 10.0, observed_at: 10.minutes.ago) # stale
      sample(hostname: "worker-a", data_root_used_percent: 73.5)
      sample(hostname: "worker-b", data_root_used_percent: 25.0)

      expect(source.worker_disk_percentages).to eq("worker-a" => 73.5, "worker-b" => 25.0)
    end

    it "excludes hosts whose latest sample has no disk reading" do
      sample(hostname: "worker-a", data_root_used_percent: nil)

      expect(source.worker_disk_percentages).to eq({})
    end
  end

  describe "#active_agent_run_count" do
    it "delegates to Run.running_agent_runs" do
      allow(Run).to receive(:running_agent_runs).and_return(Run.none)

      expect(source.active_agent_run_count).to eq(0)
    end
  end

  describe "#max_concurrent_agent_runs" do
    it "delegates to AppSetting" do
      AppSetting.current.update!(max_concurrent_agent_runs: 7)

      expect(source.max_concurrent_agent_runs).to eq(7)
    end
  end
end
