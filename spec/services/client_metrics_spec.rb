require "rails_helper"

RSpec.describe ClientMetrics do
  around do |example|
    original_registry = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original_registry)
  end

  def samples(metric)
    Syrus::Metrics.counter(metric).samples.to_h { |labels, value| [ labels[:resource], value ] }
  end

  it "records a known metric under its resource tag" do
    described_class.record(name: "entity_patch_applications", resource: "job", visibility_state: "visible")

    expect(samples(:syrus_client_entity_patch_applications_total)).to eq("job" => 1)
  end

  it "tags entity_patch_applications by visibility_state, defaulting to unknown for an unrecognized value" do
    described_class.record(name: "entity_patch_applications", resource: "job", visibility_state: "hidden")
    described_class.record(name: "entity_patch_applications", resource: "job", visibility_state: "not-a-real-state")

    labels = Syrus::Metrics.counter(:syrus_client_entity_patch_applications_total).samples.map(&:first)
    expect(labels).to contain_exactly(
      { resource: "job", visibility_state: "hidden" },
      { resource: "job", visibility_state: "unknown" }
    )
  end

  it "accepts an explicit by count" do
    described_class.record(name: "hidden_tab_suppressed_fetches", resource: "chat", by: 3)

    expect(samples(:syrus_client_hidden_tab_suppressed_fetches_total)).to eq("chat" => 3)
  end

  it "falls back to an 'unknown' resource tag for an unrecognized resource, rather than an unbounded label" do
    described_class.record(name: "revision_gap_recoveries", resource: "something-a-browser-made-up")

    expect(samples(:syrus_client_revision_gap_recoveries_total)).to eq("unknown" => 1)
  end

  it "silently ignores an unrecognized metric name instead of raising" do
    expect { described_class.record(name: "not-a-real-metric", resource: "job") }.not_to raise_error
  end

  it "clamps an implausible by value instead of trusting it verbatim" do
    described_class.record(name: "entity_patch_applications", resource: "job", by: 999_999)

    expect(samples(:syrus_client_entity_patch_applications_total)).to eq("job" => described_class::MAX_BY)
  end

  it "treats a non-numeric by as 1 instead of raising" do
    described_class.record(name: "entity_patch_applications", resource: "job", by: "not-a-number")

    expect(samples(:syrus_client_entity_patch_applications_total)).to eq("job" => 1)
  end
end
