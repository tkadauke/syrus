require "rails_helper"

RSpec.describe MetricsDashboard::DashboardPayload do
  def sample(metric:, labels:, value:, at:)
    MetricsDashboardSample.create!(
      metric: metric, labels: labels,
      series_key: MetricsDashboardSample.series_key_for(labels),
      value: value, recorded_at: at
    )
  end

  it "groups a metric into one series per label value" do
    now = Time.current.change(sec: 0)
    sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 2715, at: now - 2.minutes)
    sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 2740, at: now)
    sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "runs" }, value: 3, at: now)

    panel = described_class.build[:panels].find { |p| p[:key] == "queue_ready" }

    expect(panel[:series].map { |s| s[:name] }).to eq(%w[polling runs])
    expect(panel[:series].first[:points].map(&:last)).to eq([ 2715.0, 2740.0 ])
  end

  it "labels an unlabelled metric's single series" do
    sample(metric: "syrus_global_queue_orphaned_rows", labels: {}, value: 553_671, at: Time.current)

    panel = described_class.build[:panels].find { |p| p[:key] == "queue_orphaned" }

    expect(panel[:series].sole[:name]).to eq("total")
  end

  it "only returns samples inside the requested window" do
    now = Time.current.change(sec: 0)
    sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 1, at: now - 3.hours)
    sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 2, at: now)

    panel = described_class.build(window: "1h")[:panels].find { |p| p[:key] == "queue_ready" }

    expect(panel[:series].sole[:points].map(&:last)).to eq([ 2.0 ])
  end

  it "falls back to the default window rather than failing on a bad one" do
    expect(described_class.build(window: "nonsense")[:window]).to eq(described_class::DEFAULT_WINDOW)
  end

  # Every syrus_global_ series is one cluster-wide fact rendered identically by
  # each recorder, so summing it multiplies by the number of recorders. Encoding
  # the reduction per panel means no one has to remember the rule.
  it "declares max, not sum, as the reduction for global series" do
    global = described_class::PANELS.select { |panel| panel[:metric].start_with?("syrus_global_") }

    expect(global).to be_present
    expect(global.map { |panel| panel[:aggregate] }.uniq).to eq([ :max ])
  end

  # "No data" has two very different causes -- never recorded, or recording
  # stopped -- and an empty chart does not distinguish them.
  it "reports whether recording is current" do
    expect(described_class.build[:recording]).to be(false)
    expect(described_class.build[:last_recorded_at]).to be_nil

    sample(metric: "syrus_global_queue_orphaned_rows", labels: {}, value: 1, at: Time.current)
    expect(described_class.build[:recording]).to be(true)

    MetricsDashboardSample.update_all(recorded_at: 2.hours.ago)
    expect(described_class.build[:recording]).to be(false)
  end
end
