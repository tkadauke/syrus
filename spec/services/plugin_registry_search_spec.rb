require "rails_helper"

RSpec.describe PluginRegistrySearch do
  Source = Struct.new(:id, :name, :canonical, keyword_init: true) do
    def enabled? = true
    def canonical? = canonical
  end

  def entry(source, version: "1.0.0")
    PluginRegistryClient::Entry.new(name: "acme_weather", version:, description: "Weather", category: "tools",
      author: "Acme", homepage: "https://example.test", license: "MIT", requires_syrus: ">= 1",
      package_url: "https://example.test/a", package_digest: "a" * 64, signature_url: "https://example.test/a.sig",
      publisher_key_fingerprint: "b" * 64, trust_label: "verified", trust_label_inputs: {}, capability_summary: {},
      revoked: false, registry_name: source.name, registry_id: source.id, registry_canonical: source.canonical?)
  end

  it "merges successful registries and preserves errors per registry" do
    good = Source.new(id: 1, name: "good", canonical: true)
    bad = Source.new(id: 2, name: "bad", canonical: false)
    clients = {
      good => instance_double(PluginRegistryClient, search: PluginRegistryClient::Result.new(entries: [ entry(good) ], configured: true, error: nil, stale: false)),
      bad => instance_double(PluginRegistryClient, search: PluginRegistryClient::Result.new(entries: [], configured: true, error: "unreachable", stale: true))
    }
    result = described_class.new(sources: [ good, bad ], client_factory: ->(source) { clients.fetch(source) }).search
    expect(result.entries.map(&:name)).to eq([ "acme_weather" ])
    expect(result.errors).to eq("bad" => "unreachable")
    expect(result.stale).to eq([ "bad" ])
  end

  it "prefers canonical collisions and rejects ambiguous non-canonical matches" do
    canonical = Source.new(id: 1, name: "canonical", canonical: true)
    other = Source.new(id: 2, name: "other", canonical: false)
    search = described_class.new(sources: [ canonical, other ], client_factory: ->(source) {
      instance_double(PluginRegistryClient, search: PluginRegistryClient::Result.new(entries: [ entry(source) ], configured: true, error: nil, stale: false))
    })
    expect(search.resolve(name: "acme_weather").registry_name).to eq("canonical")

    ambiguous = described_class.new(sources: [ other, Source.new(id: 3, name: "third", canonical: false) ], client_factory: ->(source) {
      instance_double(PluginRegistryClient, search: PluginRegistryClient::Result.new(entries: [ entry(source) ], configured: true, error: nil, stale: false))
    })
    expect { ambiguous.resolve(name: "acme_weather") }.to raise_error(PluginRegistryClient::Error, /ambiguous/)
  end

  it "rejects an entry whose source is no longer enabled instead of constructing another client" do
    source = Source.new(id: 1, name: "removed", canonical: false)
    factory = instance_double(Proc)
    expect(factory).not_to receive(:call)
    search = described_class.new(sources: [], client_factory: factory)

    expect { search.client_for(entry(source)) }
      .to raise_error(PluginRegistryClient::Error, /no longer enabled: removed/)
  end

  it "keeps healthy results when an environment source has invalid configuration" do
    good = Source.new(id: 1, name: "good", canonical: true)
    invalid = PluginRegistry::InvalidEnvironmentSource.new("http://invalid.example.test", "must use HTTPS")
    search = described_class.new(sources: [ good, invalid ], client_factory: ->(source) {
      if source == good
        instance_double(PluginRegistryClient, search: PluginRegistryClient::Result.new(
          entries: [ entry(good) ], configured: true, error: nil, stale: false
        ))
      else
        PluginRegistryClient.new(source:)
      end
    })

    result = search.search

    expect(result.entries.map(&:name)).to eq([ "acme_weather" ])
    expect(result.errors).to eq(invalid.name => "must use HTTPS")
  end
end
