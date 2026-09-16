require "rails_helper"

# InstanceVersion and SpawnedProcess are ordinary ActiveRecord tables (unlike
# solid_queue_*, see CLAUDE.md), so Metrics::FleetSource is exercised
# directly with real records here rather than through a fake -- only the
# per-source degradation guard needs a stand-in.
RSpec.describe Metrics::FleetSampler do
  class FakeFleetSource
    attr_writer :instance_version_counts, :spawned_process_counts

    def initialize
      @instance_version_counts = {}
      @spawned_process_counts = {}
    end

    def instance_version_counts = resolve(@instance_version_counts)
    def spawned_process_counts(window: nil) = resolve(@spawned_process_counts)

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

  def instance_version(hostname:, role:, version:, heartbeat: Time.current)
    InstanceVersion.create!(
      hostname: hostname, role: role, version: version,
      started_at: 1.hour.ago, last_heartbeat_at: heartbeat
    )
  end

  def spawned_process(kind:, finished_at: nil, outcome: nil, started_at: 1.minute.ago)
    SpawnedProcess.create!(
      kind: kind, command: "echo hi", hostname: "worker-a",
      started_at: started_at, finished_at: finished_at, outcome: outcome
    )
  end

  describe "#sample!" do
    it "caches instance version counts by role and version" do
      instance_version(hostname: "web-1", role: "web", version: "aaa111")
      instance_version(hostname: "worker-1", role: "worker", version: "aaa111")
      instance_version(hostname: "worker-2", role: "worker", version: "bbb222")

      described_class.sample!
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_instance_versions{role="web",version="aaa111"} 1')
      expect(rendered).to include('syrus_instance_versions{role="worker",version="aaa111"} 1')
      expect(rendered).to include('syrus_instance_versions{role="worker",version="bbb222"} 1')
    end

    it "excludes an instance whose heartbeat has gone stale" do
      instance_version(hostname: "worker-1", role: "worker", version: "aaa111", heartbeat: 10.minutes.ago)

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_instance_versions{")
    end

    it "caches spawned process counts by kind and running/outcome state" do
      spawned_process(kind: "agent", finished_at: nil)
      spawned_process(kind: "agent", finished_at: Time.current, outcome: "succeeded")
      spawned_process(kind: "grader", finished_at: Time.current, outcome: "failed")

      described_class.sample!
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_spawned_processes{kind="agent",state="running"} 1')
      expect(rendered).to include('syrus_spawned_processes{kind="agent",state="succeeded"} 1')
      expect(rendered).to include('syrus_spawned_processes{kind="grader",state="failed"} 1')
    end

    it "excludes a process that finished outside the live-fleet window" do
      spawned_process(kind: "agent", started_at: 3.hours.ago, finished_at: 2.hours.ago, outcome: "succeeded")

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_spawned_processes{")
    end

    # One unreachable source costs its own gauge, not the whole sample -- same
    # degradation posture as Metrics::QueueSampler/Metrics::LandingSampler.
    it "degrades one failing source without losing the rest of the sample" do
      source = FakeFleetSource.new
      source.instance_version_counts = ActiveRecord::StatementInvalid.new("no such table")
      source.spawned_process_counts = { [ "agent", "running" ] => 2 }

      expect { described_class.sample!(source: source) }.not_to raise_error
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_spawned_processes{kind="agent",state="running"} 2')
      expect(rendered).not_to include("syrus_instance_versions{")
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_instance_versions{")
    end
  end
end
