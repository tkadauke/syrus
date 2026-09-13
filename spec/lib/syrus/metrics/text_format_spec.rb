require "rails_helper"

RSpec.describe Syrus::Metrics::TextFormat do
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    example.run
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  it "renders HELP, TYPE and labelled samples" do
    Syrus::Metrics.declare do
      counter :render_total, tags: %i[state], comment: "How many"
    end
    Syrus::Metrics.counter(:syrus_render_total).increment(by: 2, tags: { state: "succeeded" })

    expect(Syrus::Metrics.render).to eq(<<~TEXT)
      # HELP syrus_render_total How many
      # TYPE syrus_render_total counter
      syrus_render_total{state="succeeded"} 2
    TEXT
  end

  it "omits the label block for a metric with no labels" do
    Syrus::Metrics.declare { gauge :bare_depth, comment: "Depth" }
    Syrus::Metrics.gauge(:syrus_bare_depth).set(7)

    expect(Syrus::Metrics.render).to include("syrus_bare_depth 7\n")
  end

  # A declared-but-never-touched metric has no series to report. Emitting a
  # bare name with no value would be malformed.
  it "skips metrics with no samples" do
    Syrus::Metrics.declare { counter :untouched_total, comment: "Nothing yet" }

    expect(Syrus::Metrics.render).not_to include("syrus_untouched_total")
  end

  # A histogram is three families: cumulative _bucket counters, a _sum and a
  # _count. The +Inf bucket is mandatory and equals the count.
  it "renders a histogram as buckets, sum and count" do
    Syrus::Metrics.declare do
      histogram :timing_seconds, buckets: [ 1, 5 ], comment: "Timings"
    end
    histogram = Syrus::Metrics.histogram(:syrus_timing_seconds)
    histogram.observe(0.5)
    histogram.observe(3)
    histogram.observe(90)

    output = Syrus::Metrics.render
    expect(output).to include('syrus_timing_seconds_bucket{le="1"} 1')
    expect(output).to include('syrus_timing_seconds_bucket{le="5"} 2')
    expect(output).to include('syrus_timing_seconds_bucket{le="+Inf"} 3')
    expect(output).to include("syrus_timing_seconds_sum 93.5")
    expect(output).to include("syrus_timing_seconds_count 3")
  end

  it "escapes label values so a stray quote cannot corrupt the exposition" do
    Syrus::Metrics.declare { counter :escaped_total, tags: %i[reason] }
    Syrus::Metrics.counter(:syrus_escaped_total).increment(tags: { reason: 'a"b\\c' })

    expect(Syrus::Metrics.render).to include('reason="a\\"b\\\\c"')
  end

  it "advertises the exposition format version Prometheus expects" do
    expect(described_class::CONTENT_TYPE).to eq("text/plain; version=0.0.4; charset=utf-8")
  end
end
