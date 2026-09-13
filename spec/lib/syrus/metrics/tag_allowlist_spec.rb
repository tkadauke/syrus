require "rails_helper"

RSpec.describe Syrus::Metrics::TagAllowlist do
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    example.run
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  it "accepts bounded dimensions" do
    expect {
      Syrus::Metrics.declare { counter :ok_total, tags: %i[queue state trigger_kind] }
    }.not_to raise_error
  end

  # One unbounded label turns one metric into millions of series. This is the
  # single most effective way to destroy a Prometheus install, so it fails at
  # declaration rather than at 3am.
  it "rejects identifiers, and says why" do
    expect {
      Syrus::Metrics.declare { counter :bad_total, tags: %i[job_id] }
    }.to raise_error(Syrus::Metrics::Error, /identifies one Job/)

    expect {
      Syrus::Metrics.declare { counter :worse_total, tags: %i[repository] }
    }.to raise_error(Syrus::Metrics::Error, /grows with the number of repositories/)
  end

  it "rejects anything simply not on the list" do
    expect {
      Syrus::Metrics.declare { counter :novel_total, tags: %i[something_new] }
    }.to raise_error(Syrus::Metrics::Error, /not on the cardinality allowlist/)
  end

  # The privacy guarantee telemetry depends on is structural rather than
  # procedural: because no identifier can be a label, there is no repository
  # name or issue title in the store to scrub in the first place.
  it "excludes every identifying dimension from the allowlist" do
    forbidden = %i[job_id run_id workflow_id repository repository_id sha branch user_email path url]

    expect(described_class::ALLOWED & forbidden).to be_empty
  end
end
