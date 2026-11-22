require "rails_helper"

RSpec.describe PluginRegistryClient do
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:base_url) { "https://registry.example.test/" }

  before do
    allow(SsrfGuard).to receive(:safe_host?).with("registry.example.test").and_return(true)
    stub_registry
  end

  after { FileUtils.remove_entry(root) if root.exist? }

  it "parses, searches, filters incompatible releases, and hides revoked releases" do
    result = described_class.new(url: base_url, cache_root: root, syrus_version: Gem::Version.new("2.0.0")).search("weather")

    expect(result.error).to be_nil
    expect(result.entries.map { |entry| [ entry.name, entry.version, entry.trust_label ] })
      .to eq([ [ "acme_weather", "1.0.0", "verified" ] ])
  end

  it "uses conditional requests and cached files" do
    client = described_class.new(url: base_url, cache_root: root, syrus_version: Gem::Version.new("2.0.0"))
    client.search
    stub_registry(not_modified: true)

    expect(client.search.entries.map(&:name)).to include("acme_weather")
    expect(WebMock).to have_requested(:get, "#{base_url}index.json").with(headers: { "If-None-Match" => "index-v1" })
  end

  it "returns a non-fatal error for an unreachable registry" do
    stub_request(:get, "#{base_url}index.json").to_raise(SocketError.new("offline"))

    result = described_class.new(url: base_url, cache_root: root).search

    expect(result.entries).to eq([])
    expect(result.error).to include("unreachable")
  end

  it "returns a non-fatal error for a malformed index" do
    stub_request(:get, "#{base_url}index.json").to_return(body: JSON.generate(format_version: 99))

    result = described_class.new(url: base_url, cache_root: root).search

    expect(result.entries).to eq([])
    expect(result.error).to include("unsupported index format")
  end

  it "returns a clear empty state when no registry is configured" do
    expect(described_class.new(url: "", cache_root: root).search.configured).to be(false)
  end

  def stub_registry(not_modified: false)
    index = { format_version: 1, trust_store: "trust-store.json",
      releases: %w[acme_weather/1.0.0.json acme_weather/3.0.0.json acme_revoked/1.0.0.json] }
    trust = { publishers: [ { fingerprint: "abc", label: "verified" } ], revoked_keys: [ "revoked" ] }
    entries = {
      "acme_weather/1.0.0.json" => registry_entry("acme_weather", "1.0.0", ">= 1.0", "abc"),
      "acme_weather/3.0.0.json" => registry_entry("acme_weather", "3.0.0", ">= 3.0", "abc"),
      "acme_revoked/1.0.0.json" => registry_entry("acme_revoked", "1.0.0", ">= 1.0", "revoked")
    }
    bodies = { "index.json" => index, "trust-store.json" => trust }.merge(entries)
    bodies.each do |path, body|
      response = not_modified ? { status: 304 } : { body: JSON.generate(body), headers: { "ETag" => path == "index.json" ? "index-v1" : path } }
      stub_request(:get, "#{base_url}#{path}").to_return(response)
    end
  end

  def registry_entry(name, version, requirement, fingerprint)
    { name:, version:, description: "#{name} plugin", category: "automation", author: "Acme",
      homepage: "https://example.test", license: "MIT", requires_syrus: requirement,
      package_url: "https://downloads.example.test/#{name}.tar.gz", package_digest: "sha256:#{"0" * 64}",
      signature_url: "https://downloads.example.test/#{name}.sig", publisher_key_fingerprint: fingerprint,
      trust_label_inputs: { label: "community" }, capability_summary: { tools: [ "forecast" ] } }
  end
end
