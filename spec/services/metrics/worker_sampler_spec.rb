require "rails_helper"

# WorkerHostHealthSample, Run, Step and AppSetting are ordinary ActiveRecord
# tables (unlike solid_queue_*, see CLAUDE.md), so Metrics::WorkerSource is
# exercised directly with real records here rather than through a fake --
# only the per-source degradation guard needs a stand-in.
RSpec.describe Metrics::WorkerSampler do
  class FakeWorkerSource
    attr_writer :worker_cpu_percentages, :worker_memory_percentages, :worker_disk_percentages,
                :worker_hostname_labels, :active_agent_run_count, :max_concurrent_agent_runs, :finished_steps

    def initialize
      @worker_cpu_percentages = {}
      @worker_memory_percentages = {}
      @worker_disk_percentages = {}
      @worker_hostname_labels = {}
      @active_agent_run_count = 0
      @max_concurrent_agent_runs = 0
      @finished_steps = []
    end

    def worker_cpu_percentages = resolve(@worker_cpu_percentages)
    def worker_memory_percentages = resolve(@worker_memory_percentages)
    def worker_disk_percentages = resolve(@worker_disk_percentages)
    def worker_hostname_labels = resolve(@worker_hostname_labels)
    def active_agent_run_count = resolve(@active_agent_run_count)
    def max_concurrent_agent_runs = resolve(@max_concurrent_agent_runs)
    def finished_steps(after:, through:) = resolve(@finished_steps)

    private

    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def sample!(**opts) = described_class.sample!(**opts)
  def refresh!(**opts) = described_class.refresh_gauges!(**opts)

  def worker_sample(hostname:, cpu:, memory:, disk: nil, observed_at: Time.current, worker_storage_key: nil)
    WorkerHostHealthSample.create!(
      hostname: hostname, role: "worker", version: "abc123", observed_at: observed_at,
      cpu_used_percent: cpu, memory_used_percent: memory, data_root_used_percent: disk,
      worker_storage_key: worker_storage_key
    )
  end

  describe "#sample!" do
    it "caches worker cpu/memory/disk percentages from the latest sample per worker, tagged by storage key" do
      worker_sample(hostname: "worker-a", cpu: 87.5, memory: 42.0, disk: 63.0)
      worker_sample(hostname: "worker-a", cpu: 10.0, memory: 5.0, disk: 5.0, observed_at: 10.minutes.ago) # stale, excluded
      worker_sample(hostname: "worker-b", cpu: 12.0, memory: 30.0, disk: 20.0)

      sample!
      refresh!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_worker_cpu_percent{worker_storage_key="worker-a"} 87.5')
      expect(rendered).to include('syrus_worker_memory_percent{worker_storage_key="worker-a"} 42')
      expect(rendered).to include('syrus_worker_disk_percent{worker_storage_key="worker-a"} 63')
      expect(rendered).to include('syrus_worker_cpu_percent{worker_storage_key="worker-b"} 12')
      expect(rendered).to include('syrus_worker_disk_percent{worker_storage_key="worker-b"} 20')
      expect(rendered).not_to include('syrus_worker_cpu_percent{hostname=')
    end

    it "publishes syrus_worker_identity_info as the join key from storage key to hostname" do
      worker_sample(hostname: "syrus-worker-home-2kcwb", cpu: 20.0, memory: nil, disk: nil, worker_storage_key: "storage-a")

      sample!
      refresh!

      expect(Syrus::Metrics.render).to include(
        'syrus_worker_identity_info{worker_storage_key="storage-a",hostname="syrus-worker-home-2kcwb"} 1'
      )
    end

    it "keeps the cpu gauge's series identity anchored to worker_storage_key across two separate ticks under different hostnames" do
      t0 = Time.current

      travel_to(t0) do
        worker_sample(hostname: "syrus-worker-home-655ddb4df7-2kcwb", cpu: 20.0, memory: nil, disk: nil, worker_storage_key: "storage-a")
        sample!
        refresh!
      end
      expect(Syrus::Metrics.render).to include('syrus_worker_cpu_percent{worker_storage_key="storage-a"} 20')

      # Simulate a Deployment reschedule: a new pod hostname reports under the
      # same durable storage key once the old sample has aged out of the
      # 2-minute freshness window -- this is the actual restart scenario the
      # bug report describes, not two co-resident samples in one window.
      travel_to(t0 + 5.minutes) do
        worker_sample(hostname: "syrus-worker-home-6c78d87664-8ptdv", cpu: 65.0, memory: nil, disk: nil, worker_storage_key: "storage-a")
        sample!
        refresh!
      end

      rendered = Syrus::Metrics.render
      # Same tag value both ticks -- the series never forked -- just a fresh
      # reading under it.
      expect(rendered).to include('syrus_worker_cpu_percent{worker_storage_key="storage-a"} 65')
      expect(rendered).not_to include('syrus_worker_cpu_percent{worker_storage_key="syrus-worker-home-655ddb4df7-2kcwb"}')
      expect(rendered).not_to include('syrus_worker_cpu_percent{worker_storage_key="syrus-worker-home-6c78d87664-8ptdv"}')
      expect(rendered).to include(
        'syrus_worker_identity_info{worker_storage_key="storage-a",hostname="syrus-worker-home-6c78d87664-8ptdv"} 1'
      )
    end

    it "caches active_agent_runs from currently-running agentic Runs" do
      job_with_run(step_attrs: { kind: "implement" }, run_attrs: { state: "running" })
      job_with_run(step_attrs: { kind: "grader" }, run_attrs: { state: "running" }) # not agentic

      sample!
      refresh!

      expect(Syrus::Metrics.render).to include("syrus_active_agent_runs 1")
    end

    it "caches max_concurrent_agent_runs from AppSetting" do
      AppSetting.current.update!(max_concurrent_agent_runs: 7)

      sample!
      refresh!

      expect(Syrus::Metrics.render).to include("syrus_max_concurrent_agent_runs 7")
    end

    it "bootstraps the step-duration cursor on the first tick without instrumenting existing history" do
      t0 = Time.current
      travel_to(t0 - 1.hour) do
        job_with_run(step_attrs: { kind: "implement", state: "succeeded", started_at: Time.current - 30, finished_at: Time.current })
      end

      travel_to(t0) { sample! }
      refresh!

      expect(Syrus::Metrics.render).not_to include("syrus_workflow_step_duration_seconds_count{")
    end

    it "instruments a Step that finishes after the first tick into workflow_step_duration_seconds" do
      t0 = Time.current
      travel_to(t0) { sample! } # bootstrap

      travel_to(t0 + 1.minute) do
        job_with_run(step_attrs: { kind: "implement", state: "succeeded", started_at: Time.current - 30, finished_at: Time.current })
      end

      travel_to(t0 + 2.minutes) { sample! }
      refresh!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_workflow_step_duration_seconds_bucket{kind="implement",le="60"} 1')
      expect(rendered).to include('syrus_workflow_step_duration_seconds_count{kind="implement"} 1')
    end

    it "does not double-count a Step already instrumented on a prior tick" do
      t0 = Time.current
      travel_to(t0) { sample! }

      travel_to(t0 + 1.minute) do
        job_with_run(step_attrs: { kind: "implement", state: "succeeded", started_at: Time.current - 5, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { sample! }
      travel_to(t0 + 3.minutes) { sample! }

      refresh!
      refresh!

      expect(Syrus::Metrics.render).to include('syrus_workflow_step_duration_seconds_count{kind="implement"} 1')
    end

    # One unreachable source costs its own gauge/counter, not the whole tick --
    # same degradation posture as Metrics::QueueSampler/Metrics::LandingSampler.
    it "degrades one failing source without losing the rest of the sample" do
      source = FakeWorkerSource.new
      source.worker_cpu_percentages = ActiveRecord::StatementInvalid.new("no such table")
      source.active_agent_run_count = 4

      expect { sample!(source: source) }.not_to raise_error
      refresh!(source: source)

      expect(Syrus::Metrics.render).to include("syrus_active_agent_runs 4")
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(refresh!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_active_agent_runs")
    end
  end
end
