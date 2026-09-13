require "rails_helper"

# Rails.cache is :null_store in test, so a cache round-trip needs a real store.
RSpec.describe Metrics::PluginSampler do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  # See product_usage_spec: a global registry reset has to be undone.
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  it "records which installed plugins are on and which are off" do
    described_class.sample!

    expect(described_class.refresh_gauges!).to be(true)

    rendered = Syrus::Metrics.render
    expect(rendered).to match(/syrus_global_plugin_enabled\{plugin="[a-z_]+"\} [01]/)
  end

  # A disabled plugin declares no metrics of its own, so its absence from the
  # dashboard is ambiguous: switched off, or enabled and simply unused? This
  # gauge is what separates them, which is why a disabled plugin must still
  # report -- as 0, not as nothing.
  it "reports a disabled plugin as 0 rather than omitting it" do
    cache.write(described_class::CACHE_KEY, { "video_walkthroughs" => false, "github_source" => true })

    described_class.refresh_gauges!

    rendered = Syrus::Metrics.render
    expect(rendered).to include('syrus_global_plugin_enabled{plugin="video_walkthroughs"} 0')
    expect(rendered).to include('syrus_global_plugin_enabled{plugin="github_source"} 1')
  end

  it "reports nothing rather than guessing when no sample has been taken" do
    expect(described_class.refresh_gauges!).to be(false)
  end

  # PluginRegistry.all_plugins reads plugin_records, so a database that cannot
  # be reached must cost this gauge and nothing else.
  it "degrades when the registry cannot be read" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_raise(ActiveRecord::StatementInvalid, "nope")

    expect { described_class.sample! }.not_to raise_error
    expect(described_class.sample!).to eq({})
  end
end
