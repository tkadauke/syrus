require "rails_helper"

RSpec.describe MetricsDashboard::Recorder do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def render_metrics(text)
    allow(Syrus::Metrics).to receive(:render).and_return(text)
    allow(Metrics::QueueSampler).to receive(:refresh_gauges!).and_return(true)
    allow(Metrics::PluginSampler).to receive(:refresh_gauges!).and_return(true)
  end

  it "records each series from the exposition text" do
    render_metrics(<<~TEXT)
      # HELP syrus_global_queue_ready_count Ready
      # TYPE syrus_global_queue_ready_count gauge
      syrus_global_queue_ready_count{queue="polling"} 2715
      syrus_global_queue_ready_count{queue="runs"} 4
      syrus_global_queue_orphaned_rows 553671
    TEXT

    expect(described_class.record!).to eq(3)

    polling = MetricsDashboardSample.find_by(metric: "syrus_global_queue_ready_count", series_key: "queue=polling")
    expect(polling.value).to eq(2715)
    expect(polling.labels).to eq({ "queue" => "polling" })

    orphans = MetricsDashboardSample.find_by(metric: "syrus_global_queue_orphaned_rows")
    expect(orphans.value).to eq(553_671)
    expect(orphans.series_key).to eq("")
  end

  # Two ticks landing in the same minute must not create two rows, or the chart
  # shows a sawtooth that is an artefact of scheduling rather than of the system.
  it "is idempotent within a minute" do
    render_metrics("syrus_global_queue_ready_count{queue=\"polling\"} 10\n")
    now = Time.current.change(sec: 0)

    described_class.record!(now: now)
    render_metrics("syrus_global_queue_ready_count{queue=\"polling\"} 25\n")
    described_class.record!(now: now + 30.seconds)

    samples = MetricsDashboardSample.where(metric: "syrus_global_queue_ready_count")
    expect(samples.count).to eq(1)
    expect(samples.sole.value).to eq(25), "the later value in the minute should win"
  end

  it "keeps successive minutes as separate points" do
    render_metrics("syrus_global_queue_ready_count{queue=\"polling\"} 10\n")
    base = Time.current.change(sec: 0)

    described_class.record!(now: base)
    described_class.record!(now: base + 1.minute)

    expect(MetricsDashboardSample.where(metric: "syrus_global_queue_ready_count").count).to eq(2)
  end

  # A recorder that raises would fail the plugin tick and could retry into a
  # loop. Losing a minute of chart is the cheaper outcome by far.
  it "records nothing rather than raising when metrics cannot be rendered" do
    allow(Metrics::QueueSampler).to receive(:refresh_gauges!).and_raise(ActiveRecord::StatementInvalid, "nope")

    expect { described_class.record! }.not_to raise_error
    expect(MetricsDashboardSample.count).to eq(0)
  end

  # Histograms are exposed as _bucket/_sum/_count families. Charting a quantile
  # means re-deriving it from buckets, which is a query engine's job.
  #
  # Identified from the `# TYPE` declaration, not by name: four of the queue
  # gauges end in `_count` and suffix matching alone silently dropped them.
  it "skips histogram families" do
    render_metrics(<<~TEXT)
      # TYPE syrus_run_duration_seconds histogram
      syrus_run_duration_seconds_bucket{le="1"} 4
      syrus_run_duration_seconds_sum 12.5
      syrus_run_duration_seconds_count 4
      syrus_feature_used_total{feature="chat_created"} 7
    TEXT

    described_class.record!

    expect(MetricsDashboardSample.pluck(:metric)).to eq([ "syrus_feature_used_total" ])
  end

  it "keeps a gauge whose name merely ends in a histogram suffix" do
    render_metrics(<<~TEXT)
      # TYPE syrus_global_queue_ready_count gauge
      syrus_global_queue_ready_count{queue="polling"} 12
      # TYPE syrus_global_queue_blocked_count gauge
      syrus_global_queue_blocked_count 3
    TEXT

    described_class.record!

    expect(MetricsDashboardSample.pluck(:metric)).to contain_exactly(
      "syrus_global_queue_ready_count", "syrus_global_queue_blocked_count"
    )
  end
end
