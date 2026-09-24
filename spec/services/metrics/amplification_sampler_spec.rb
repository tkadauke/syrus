require "rails_helper"

RSpec.describe Metrics::AmplificationSampler do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original_registry = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    AppEvents.declare_metrics!
    App::JobWorkflowsSnapshotCache.declare_metrics!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original_registry)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def deliver_events(resource, count)
    count.times { Syrus::Metrics.counter(:syrus_app_events_delivered_total).increment(tags: { resource: resource }) }
  end

  def record_requests(resource, outcome, count)
    count.times { Syrus::Metrics.counter(:syrus_detail_snapshot_requests_total).increment(tags: { resource: resource, outcome: outcome }) }
  end

  def flush_cluster_counters
    Metrics::ClusterCounters.flush!
  end

  it "reports no ratio on the first tick, since there is no prior window to diff against" do
    deliver_events("job", 4)
    record_requests("job", "computed", 2)
    flush_cluster_counters

    described_class.sample!
    described_class.refresh_gauges!

    expect(Syrus::Metrics.render).not_to include("syrus_event_amplification_ratio")
  end

  it "reports requests-computed-per-event as a ratio over the delta since the previous tick" do
    deliver_events("job", 4)
    record_requests("job", "computed", 2)
    flush_cluster_counters
    described_class.sample! # baseline tick

    deliver_events("job", 6) # +6 events
    record_requests("job", "computed", 3) # +3 computed requests
    record_requests("job", "cache_hit", 100) # cache hits must not count as "requests caused"
    flush_cluster_counters

    described_class.sample!
    described_class.refresh_gauges!

    expect(Syrus::Metrics.render).to include('syrus_event_amplification_ratio{resource="job"} 0.5')
  end

  it "omits the ratio for a resource with no events in the window rather than dividing by zero" do
    record_requests("job", "computed", 2)
    flush_cluster_counters
    described_class.sample!

    record_requests("job", "computed", 3) # events stay flat; requests still move
    flush_cluster_counters
    described_class.sample!
    described_class.refresh_gauges!

    expect(Syrus::Metrics.render).not_to include("syrus_event_amplification_ratio")
  end

  it "clears the ratio once the cached sample has expired" do
    deliver_events("job", 2)
    record_requests("job", "computed", 1)
    flush_cluster_counters
    described_class.sample!

    deliver_events("job", 2)
    record_requests("job", "computed", 1)
    flush_cluster_counters
    described_class.sample!
    described_class.refresh_gauges!
    expect(Syrus::Metrics.render).to include('syrus_event_amplification_ratio{resource="job"}')

    cache.clear

    described_class.refresh_gauges!

    expect(Syrus::Metrics.render).not_to include("syrus_event_amplification_ratio")
  end

  describe "#refresh_gauges!" do
    it "reports false and nothing rendered when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_event_amplification_ratio")
    end
  end
end
