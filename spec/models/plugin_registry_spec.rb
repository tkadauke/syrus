require "rails_helper"

RSpec.describe PluginRegistry do
  before { allow(SsrfGuard).to receive(:safe_host?).and_return(true) }

  it "identifies and seeds the enabled canonical registry by URL" do
    registry = described_class.ensure_canonical!
    expect(registry).to have_attributes(name: "canonical", enabled: true)
    expect(registry).to be_canonical
  end

  it "validates transport, credentials, uniqueness, and the configured limit" do
    expect(described_class.new(name: "bad", url: "http://example.test")).not_to be_valid
    expect(described_class.new(name: "bad", url: "https://user:secret@example.test")).not_to be_valid
    described_class.create!(name: "one", url: "https://one.example.test")
    expect(described_class.new(name: "one", url: "https://two.example.test")).not_to be_valid
    stub_const("PluginRegistry::MAX_CONFIGURED", described_class.count)
    expect(described_class.new(name: "two", url: "https://two.example.test")).not_to be_valid
  end

  it "adds an environment registry as a read-only source" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_PLUGIN_REGISTRY_URL").and_return("https://legacy.example.test")
    source = described_class.sources.find(&:read_only?)
    expect(source).to have_attributes(url: "https://legacy.example.test", enabled?: true, environment_managed?: true)
    expect(source).to be_persisted
  end
end
