require "rails_helper"

RSpec.describe MetricsDashboard::DashboardPayload do
  def sample(metric:, value:, at:, labels: {})
    MetricsDashboard::Sample.create!(
      metric: metric, labels: labels,
      series_key: MetricsDashboard::Sample.series_key_for(labels),
      value: value, recorded_at: at
    )
  end

  def panel(payload, key) = payload[:panels].find { |p| p[:key] == key }

  describe "the shared bucket grid" do
    # Every panel is sampled onto the same timestamps so index i means the same
    # instant everywhere. That is what lets the UI draw one crosshair across all
    # the charts, and it is why the grid lives at payload level.
    it "publishes one grid every panel is aligned to" do
      payload = described_class.build(window: "6h")

      expect(payload[:bucket_seconds]).to eq(5.minutes.to_i)
      expect(payload[:buckets].size).to eq(6.hours / 5.minutes + 1)

      lengths = payload[:panels].flat_map { |p| p[:series].map { |s| s[:values].size } }.uniq
      expect(lengths - [ payload[:buckets].size ]).to be_empty
    end

    it "uses a coarser bucket for a longer window" do
      expect(described_class.build(window: "1h")[:bucket_seconds]).to eq(60)
      expect(described_class.build(window: "7d")[:bucket_seconds]).to eq(1.hour.to_i)
    end

    it "aligns the grid so two builds of the same window agree" do
      expect(described_class.build(window: "6h")[:buckets])
        .to eq(described_class.build(window: "6h")[:buckets])
    end
  end

  describe "gauge panels" do
    it "reports the highest reading in each bucket" do
      now = Time.current.change(sec: 0)
      sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 10, at: now - 1.minute)
      sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 40, at: now - 2.minutes)

      values = panel(described_class.build(window: "6h"), "queue_ready")[:series].sole[:values].compact

      expect(values.max).to eq(40)
    end

    # A gap in recording is not a drop to zero, and drawing it as one would
    # invent an outage that did not happen.
    it "leaves buckets with no sample empty rather than zero" do
      sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" }, value: 5, at: Time.current)

      values = panel(described_class.build(window: "6h"), "queue_ready")[:series].sole[:values]

      expect(values.count(&:nil?)).to be > 1
      expect(values).not_to include(0)
    end
  end

  describe "rate panels" do
    # A cumulative counter drawn raw is a flat line at a big number:
    # syrus_global_queue_failed_count sat at 3,319 all day, which says nothing
    # about whether anything is failing now.
    it "reports the change per bucket rather than the running total" do
      now = Time.current.change(sec: 0)
      labels = { "job_class" => "PollPullRequestJob" }
      sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 3300, at: now - 12.minutes)
      sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 3310, at: now - 7.minutes)
      sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 3319, at: now - 1.minute)

      values = panel(described_class.build(window: "6h"), "queue_failed")[:series].sole[:values].compact

      expect(values.sum).to eq(19), "should report 19 new failures, not the 3,319 total"
      expect(values.max).to be < 3300
    end

    # An in-memory counter returns to zero when its process restarts. PromQL
    # treats the drop as a reset and counts the new value; so does this.
    it "treats a decrease as a counter reset instead of a negative rate" do
      now = Time.current.change(sec: 0)
      labels = { "feature" => "chat_created" }
      sample(metric: "syrus_feature_used_total", labels: labels, value: 100, at: now - 12.minutes)
      sample(metric: "syrus_feature_used_total", labels: labels, value: 3, at: now - 1.minute)

      values = panel(described_class.build(window: "6h"), "feature_usage")[:series].sole[:values].compact

      expect(values).to all(be >= 0)
      expect(values.sum).to eq(3)
    end

    # "Nothing failed in this bucket" is a real reading; only buckets outside
    # what we observed are unknown.
    it "reports zero inside the observed range and nothing outside it" do
      now = Time.current.change(sec: 0)
      labels = { "job_class" => "RunJob" }
      sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 5, at: now - 20.minutes)
      sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 5, at: now - 1.minute)

      values = panel(described_class.build(window: "6h"), "queue_failed")[:series].sole[:values]

      expect(values).to include(0)
      expect(values).to include(nil)
    end

    it "keeps only the series that moved, so a rate panel stays readable" do
      now = Time.current.change(sec: 0)
      12.times do |i|
        labels = { "job_class" => "Static#{i}Job" }
        sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 7, at: now - 10.minutes)
        sample(metric: "syrus_global_queue_failed_count", labels: labels, value: 7, at: now - 1.minute)
      end
      moving = { "job_class" => "MovingJob" }
      sample(metric: "syrus_global_queue_failed_count", labels: moving, value: 1, at: now - 10.minutes)
      sample(metric: "syrus_global_queue_failed_count", labels: moving, value: 90, at: now - 1.minute)

      series = panel(described_class.build(window: "6h"), "queue_failed")[:series]

      expect(series.size).to be <= described_class::RATE_SERIES_LIMIT
      expect(series.map { |s| s[:name] }).to include("MovingJob")
    end
  end

  it "labels an unlabelled metric's single series" do
    sample(metric: "syrus_global_queue_orphaned_rows", value: 553_671, at: Time.current)

    expect(panel(described_class.build, "queue_orphaned")[:series].sole[:name]).to eq("total")
  end

  it "falls back to the default window rather than failing on a bad one" do
    expect(described_class.build(window: "nonsense")[:window]).to eq(described_class::DEFAULT_WINDOW)
  end

  it "declares max, not sum, as the reduction for global gauge series" do
    global = described_class::PANELS.select do |p|
      p[:metric].start_with?("syrus_global_") && p[:mode] == :value
    end

    expect(global).to be_present
    expect(global.map { |p| p[:aggregate] }.uniq).to eq([ :max ])
  end

  # "No data" has two very different causes -- never recorded, or recording
  # stopped -- and an empty chart does not distinguish them.
  it "reports whether recording is current" do
    expect(described_class.build[:recording]).to be(false)

    sample(metric: "syrus_global_queue_orphaned_rows", value: 1, at: Time.current)
    expect(described_class.build[:recording]).to be(true)

    MetricsDashboard::Sample.update_all(recorded_at: 2.hours.ago)
    expect(described_class.build[:recording]).to be(false)
  end
end
