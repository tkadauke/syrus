require "rails_helper"

RSpec.describe Syrus::Metrics do
  around do |example|
    original = described_class.registry
    described_class.reset!
    example.run
    described_class.instance_variable_set(:@registry, original)
  end

  describe "counters" do
    before do
      described_class.declare do
        counter :test_runs_total, tags: %i[state], comment: "Runs by state"
      end
    end

    it "accumulates" do
      counter = described_class.counter(:syrus_test_runs_total)
      counter.increment(tags: { state: "succeeded" })
      counter.increment(by: 3, tags: { state: "succeeded" })
      counter.increment(tags: { state: "failed" })

      expect(counter.samples).to contain_exactly(
        [ { state: "succeeded" }, 4 ],
        [ { state: "failed" }, 1 ]
      )
    end

    # The whole design rests on counters being cumulative: rates are computed at
    # read time by rate(), which is what removes the "did we reset before or
    # after the scrape read it?" class of bug. A counter that can go down is a
    # counter PromQL will read as a process restart and silently compensate for.
    it "refuses to go backwards" do
      counter = described_class.counter(:syrus_test_runs_total)

      expect { counter.increment(by: -1, tags: { state: "failed" }) }
        .to raise_error(ArgumentError, /only increase/)
      expect(counter).not_to respond_to(:set)
      expect(counter).not_to respond_to(:decrement)
    end

    # An unused feature and an uninstrumented one look identical on a dashboard
    # unless the zero is published, and "which features does nobody use" is a
    # question we intend to answer.
    it "can publish a zero series without incrementing it" do
      counter = described_class.counter(:syrus_test_runs_total)
      counter.preset(tags: { state: "cancelled" })

      expect(counter.samples).to eq([ [ { state: "cancelled" }, 0 ] ])
    end
  end

  describe "gauges" do
    before do
      described_class.declare { gauge :test_depth, tags: %i[queue] }
    end

    it "takes absolute values and moves in both directions" do
      gauge = described_class.gauge(:syrus_test_depth)
      gauge.set(10, tags: { queue: "polling" })
      gauge.set(4, tags: { queue: "polling" })
      gauge.increment(tags: { queue: "polling" })
      gauge.decrement(by: 2, tags: { queue: "polling" })

      expect(gauge.samples).to eq([ [ { queue: "polling" }, 3 ] ])
    end
  end

  describe "histograms" do
    before do
      described_class.declare do
        histogram :test_duration_seconds, buckets: [ 1, 5, 10 ], tags: %i[step_kind]
      end
    end

    it "accumulates cumulative buckets, a sum and a count" do
      histogram = described_class.histogram(:syrus_test_duration_seconds)
      [ 0.5, 3, 7, 50 ].each { |v| histogram.observe(v, tags: { step_kind: "implement" }) }

      _labels, entry = histogram.samples.first
      # Cumulative: each bucket counts observations <= its bound, which is what
      # makes buckets summable across processes.
      expect(entry[:buckets]).to eq({ 1.0 => 1, 5.0 => 2, 10.0 => 3 })
      expect(entry[:count]).to eq(4)
      expect(entry[:sum]).to eq(60.5)
    end

    it "records how long a block took, including when it raised" do
      histogram = described_class.histogram(:syrus_test_duration_seconds)

      expect {
        histogram.measure(tags: { step_kind: "implement" }) { raise "boom" }
      }.to raise_error("boom")

      _labels, entry = histogram.samples.first
      expect(entry[:count]).to eq(1)
    end

    it "requires buckets" do
      expect {
        described_class.declare { histogram :no_buckets, buckets: [] }
      }.to raise_error(described_class::Error, /must declare buckets/)
    end
  end

  # Client-side quantiles cannot be aggregated across processes: there is no
  # function of two pods' p99 values that yields the combined p99. Histograms
  # aggregate because their buckets are counters.
  it "offers no summary instrument" do
    expect { described_class.declare { summary :nope } }.to raise_error(NoMethodError)
    expect(Syrus::Metrics::Definition::TYPES).to contain_exactly(:counter, :gauge, :histogram)
  end

  describe "duplicate declarations" do
    it "raises rather than letting one declaration silently shadow another" do
      described_class.declare { counter :dupe_total }

      expect {
        described_class.declare(owner: "other") { gauge :dupe_total }
      }.to raise_error(described_class::Error, /already declared by core/)
    end

    # Reloads re-run to_prepare, which re-declares. An identical redeclaration
    # is not a conflict.
    it "tolerates an identical redeclaration" do
      described_class.declare { counter :idempotent_total, tags: %i[state] }

      expect { described_class.declare { counter :idempotent_total, tags: %i[state] } }
        .not_to raise_error
    end
  end

  describe "unknown metrics" do
    it "raises in development and test, where it is a programming error" do
      expect { described_class.counter(:syrus_never_declared) }
        .to raise_error(described_class::UnknownMetric, /not declared/)
    end

    # A metrics bug must never fail a Run. In production the call site keeps
    # working and the series is simply missing.
    it "degrades to a no-op in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      counter = described_class.counter(:syrus_never_declared)

      expect { counter.increment(tags: { state: "x" }) }.not_to raise_error
      expect(counter.samples).to eq([])
    end
  end

  it "rejects a type mismatch rather than mis-rendering the series" do
    described_class.declare { counter :typed_total }

    expect { described_class.gauge(:syrus_typed_total) }
      .to raise_error(described_class::UnknownMetric, /is a counter, not a gauge/)
  end
end
