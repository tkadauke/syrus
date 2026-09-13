require "rails_helper"

RSpec.describe Metrics::ProductUsage do
  # The registry is process-global, so a reset must be undone or every later
  # spec (and the catalog drift guard) sees a registry missing most metrics.
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  it "counts a feature use" do
    described_class.record(:direct_job_created)
    described_class.record(:direct_job_created)
    described_class.record(:epic_created)

    expect(Syrus::Metrics.render).to include('syrus_feature_used_total{feature="direct_job_created"} 2')
    expect(Syrus::Metrics.render).to include('syrus_feature_used_total{feature="epic_created"} 1')
  end

  # The entire point of collecting these is finding features nobody uses, and an
  # unused counter is indistinguishable from an uninstrumented one -- both are a
  # missing series -- unless the zero is published.
  it "publishes a zero for every feature so an unused one is visible" do
    described_class.preset_all!

    rendered = Syrus::Metrics.render
    described_class::FEATURES.each do |feature|
      expect(rendered).to include(%(syrus_feature_used_total{feature="#{feature}"} 0))
    end
  end

  it "does not reset a real count back to zero when presetting again" do
    described_class.record(:chat_created)
    described_class.preset_all!

    expect(Syrus::Metrics.render).to include('syrus_feature_used_total{feature="chat_created"} 1')
  end

  # Product analytics is exactly where someone reaches for a user-supplied
  # string as a label, which is how a metrics system acquires unbounded
  # cardinality. The feature list is a closed enum.
  it "rejects an unknown feature in development and test" do
    expect { described_class.record(:something_made_up) }
      .to raise_error(ArgumentError, /unknown feature/)
  end

  # ...but a bad call site must not take down a request in production.
  it "ignores an unknown feature in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    expect { described_class.record(:something_made_up) }.not_to raise_error
  end
end
