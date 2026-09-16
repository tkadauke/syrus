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
      expect(described_class.build(window: "1h")[:bucket_seconds]).to eq(3.minutes.to_i)
      expect(described_class.build(window: "7d")[:bucket_seconds]).to eq(1.hour.to_i)
    end

    # The recorder ticks once a minute nominally but lands about every 89
    # seconds in practice. Any bucket narrower than that misses samples
    # routinely, which is what turned every chart into a comb.
    it "never buckets more finely than the recorder can sample" do
      described_class::WINDOWS.each do |name, config|
        expect(config[:bucket]).to be >= 2 * MetricsDashboard::SAMPLE_INTERVAL,
          "#{name} buckets at #{config[:bucket]}s, too fine for the recorder's cadence"
      end
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

    # The recorder samples about every 89 seconds against a fixed grid, so
    # buckets are missed routinely. A gauge holds its value across those: the
    # quantity did not vanish, we just did not look. Before this, a constant
    # 553k line rendered as a dashed comb.
    it "holds a gauge's value across a bucket the recorder skipped" do
      now = Time.current.change(sec: 0)
      labels = { "queue" => "polling" }
      # Six minutes apart in the 1h window's three-minute buckets: one bucket
      # in the middle gets no sample, which is the shape the jittering recorder
      # actually produces.
      sample(metric: "syrus_global_queue_ready_count", labels: labels, value: 40, at: now - 7.minutes)
      sample(metric: "syrus_global_queue_ready_count", labels: labels, value: 40, at: now - 1.minute)

      values = panel(described_class.build(window: "1h"), "queue_ready")[:series].sole[:values]
      first = values.index { |v| !v.nil? }
      last = values.rindex { |v| !v.nil? }

      expect(values[first..last]).to all(eq(40)),
        "a skipped bucket should hold the last reading, not punch a hole"
    end

    # The other kind of gap is real, and must survive: once the recorder has
    # genuinely stopped, a line still drawing its last value is a confident lie.
    it "stops holding the value once the samples are older than the staleness bound" do
      sample(metric: "syrus_global_queue_ready_count", labels: { "queue" => "polling" },
             value: 5, at: 90.minutes.ago)

      values = panel(described_class.build(window: "6h"), "queue_ready")[:series].sole[:values]

      expect(values.last).to be_nil
      expect(values.compact).to all(eq(5))
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

  describe "panel categories" do
    # A panel EPIC-359 named slightly differently than guessed ahead of time is
    # exactly the drift this guards against: every real panel must declare a
    # real category, not quietly ride the "other" fallback.
    it "assigns every panel a real category, not the fallback" do
      described_class::PANELS.each do |panel|
        expect(described_class::CATEGORIES).to include(panel[:category]),
          "#{panel[:key]} has no real category (#{panel[:category].inspect})"
      end
    end

    it "publishes each panel's category in the built payload" do
      payload = described_class.build(window: "6h")

      by_key = payload[:panels].index_by { |p| p[:key] }
      expect(by_key["queue_ready"][:category]).to eq(described_class::CATEGORY_QUEUE_THROUGHPUT)
      expect(by_key["worker_cpu"][:category]).to eq(described_class::CATEGORY_WORKERS_FLEET)
      expect(by_key["feature_usage"][:category]).to eq(described_class::CATEGORY_RESILIENCE_PRODUCT)
    end

    it "publishes the canonical category order without 'other' when nothing fell back to it" do
      expect(described_class.build(window: "6h")[:categories]).to eq(described_class::CATEGORIES)
    end

    # A panel that forgets `category:` must not silently disappear -- it lands
    # on a clearly-labeled "Other" tab instead of vanishing from the dashboard.
    it "falls a panel with no declared category back to 'other' instead of dropping it" do
      uncategorized_panel = { key: "mystery", metric: "syrus_does_not_exist", group_by: nil, mode: :value, unit: "x" }

      expect(described_class.category_for(uncategorized_panel)).to eq(described_class::CATEGORY_OTHER)
    end

    it "appends 'other' to the published category order only when a panel actually falls back to it" do
      stub_const("MetricsDashboard::DashboardPayload::PANELS",
                 described_class::PANELS + [ { key: "mystery", metric: "syrus_does_not_exist",
                                                group_by: nil, mode: :value, unit: "x" } ])

      expect(described_class.build(window: "6h")[:categories]).to eq(described_class::CATEGORIES + [ described_class::CATEGORY_OTHER ])
    end
  end

  describe "plugin-contributed tabs" do
    # A fake, non-existent plugin name throughout -- metrics_dashboard core
    # specs must not enumerate the plugins that actually contribute
    # (spending_insights, throughput, ...), mirroring
    # sidecar_registry_tool_names's approach in
    # spec/services/mcp_tool_registry_spec.rb. See
    # MetricsDashboard::PluginTabs's own spec for the collection mechanism;
    # this covers only how DashboardPayload folds the result in.
    #
    # Real bundled plugins already contribute their own tabs unconditionally
    # once this plugin is enabled, so `:plugin_tabs` is never empty by
    # default here -- examples below assert against the fake contribution
    # specifically (find/include), never a bare `eq([])`.
    def register_tab(panels:, name: "widget_metrics", id: "widgets", label: "Widgets")
      provider = Class.new do
        define_singleton_method(:metrics_dashboard_tabs) { [ { id: id, label: label, panels: panels } ] }
      end
      Syrus::PluginRegistry.register(name: name, version: "1.0.0", provides: { "metrics_dashboard:tab" => provider })
      PluginRecord.find_or_create_by!(name: name).update!(enabled: true, disableable: true)
    end

    before { PluginRecord.find_or_create_by!(name: "metrics_dashboard").update!(enabled: true, disableable: true) }

    it "publishes a contributed tab's id and label alongside the core categories" do
      register_tab(panels: [])

      expect(described_class.build(window: "6h")[:plugin_tabs]).to include({ id: "widgets", label: "Widgets" })
      expect(described_class.build(window: "6h")[:categories]).to eq(described_class::CATEGORIES)
    end

    it "queries a contributed panel the same way as a core one, tagged with the tab's id as its category" do
      now = Time.current.change(sec: 0)
      sample(metric: "syrus_widget_metrics_widgets_total", labels: {}, value: 5, at: now - 1.minute)
      register_tab(panels: [
        { key: "widgets_total", metric: "syrus_widget_metrics_widgets_total", group_by: nil, mode: :value, unit: "widgets", label: "Widgets" }
      ])

      contributed = panel(described_class.build(window: "6h"), "widgets_total")

      expect(contributed[:category]).to eq("widgets")
      expect(contributed[:label]).to eq("Widgets")
      expect(contributed[:series].sole[:values].compact.max).to eq(5)
    end

    it "omits a core panel's label, so the frontend keeps translating it by key" do
      expect(panel(described_class.build(window: "6h"), "queue_ready")).not_to have_key(:label)
    end

    it "contributes no tab or panel while the contributing plugin is disabled" do
      register_tab(panels: [ { key: "widgets_total", metric: "syrus_widget_metrics_widgets_total", group_by: nil, mode: :value, unit: "widgets", label: "Widgets" } ])
      PluginRecord.find_by!(name: "widget_metrics").update!(enabled: false)

      payload = described_class.build(window: "6h")

      expect(payload[:plugin_tabs].map { |tab| tab[:id] }).not_to include("widgets")
      expect(payload[:panels].map { |p| p[:key] }).not_to include("widgets_total")
    end
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
