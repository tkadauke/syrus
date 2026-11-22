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
    expect(Syrus::PluginPackage::TrustStore).not_to receive(:cache!)
    result = described_class.new(url: base_url, cache_root: root, syrus_version: Gem::Version.new("2.0.0")).search("weather")

    expect(result.error).to be_nil
    expect(result.entries.map { |entry| [ entry.name, entry.version, entry.trust_label ] })
      .to eq([ [ "acme_weather", "1.0.0", "verified" ] ])
  end

  it "looks up compatible entries by name and optional version" do
    client = described_class.new(url: base_url, cache_root: root, syrus_version: Gem::Version.new("2.0.0"))

    expect(client.entry(name: "acme_weather").version).to eq("1.0.0")
    expect(client.entry(name: "acme_weather", version: "1.0.0").trust_label_inputs).to eq("label" => "community")
    expect { client.entry(name: "acme_missing") }.to raise_error(described_class::Error, /not present/)
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

  it "serves the last coherent cache when a refresh fails partway through" do
    client = described_class.new(url: base_url, cache_root: root, syrus_version: Gem::Version.new("2.0.0"))
    expect(client.search.entries.map(&:name)).to include("acme_weather")
    stub_registry
    stub_request(:get, "#{base_url}trust-store.json").to_raise(SocketError.new("offline"))

    result = client.search

    expect(result.entries.map(&:name)).to include("acme_weather")
    expect(result.stale).to be(true)
    expect(result.error).to include("unreachable")
  end

  it "clones a git registry once within the refresh interval" do
    client = described_class.new(url: "git+https://registry.example.test/plugins.git", cache_root: root,
      syrus_version: Gem::Version.new("2.0.0"))
    allow(Open3).to receive(:capture3) do |*_arguments|
      materialize_registry(root.join("index"))
      [ "", "", instance_double(Process::Status, success?: true) ]
    end

    expect(client.search.entries.map(&:name)).to include("acme_weather")
    expect(client.search.entries.map(&:name)).to include("acme_weather")
    expect(Open3).to have_received(:capture3).once
  end

  it "rejects git registry symlinks that escape the checkout" do
    client = described_class.new(url: "git+https://registry.example.test/plugins.git", cache_root: root,
      syrus_version: Gem::Version.new("2.0.0"))
    outside = root.join("outside.json")
    outside.write(JSON.generate(registry_entry("acme_weather", "1.0.0", ">= 1.0", "abc")))
    allow(Open3).to receive(:capture3) do |*_arguments|
      materialize_registry(root.join("index"))
      root.join("index/acme_weather/1.0.0.json").delete
      File.symlink(outside, root.join("index/acme_weather/1.0.0.json"))
      [ "", "", instance_double(Process::Status, success?: true) ]
    end

    result = client.search

    expect(result.entries).to eq([])
    expect(result.error).to include("escapes the index root")
  end

  it "stores git refresh metadata outside the untrusted checkout" do
    client = described_class.new(url: "git+https://registry.example.test/plugins.git", cache_root: root,
      syrus_version: Gem::Version.new("2.0.0"))
    outside = root.join("outside.txt")
    outside.write("preserve me")
    FileUtils.touch(outside, mtime: Time.at(1))
    allow(Open3).to receive(:capture3) do |*_arguments|
      materialize_registry(root.join("index"))
      File.symlink(outside, root.join("index/.syrus-refreshed-at"))
      [ "", "", instance_double(Process::Status, success?: true) ]
    end

    expect(client.search.entries.map(&:name)).to include("acme_weather")
    expect(outside.read).to eq("preserve me")
    expect(outside.mtime).to eq(Time.at(1))
    expect(root.join("git-refreshed-at")).to be_file
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

  def materialize_registry(destination)
    FileUtils.mkdir_p(destination)
    index = { format_version: 1, trust_store: "trust-store.json", releases: [ "acme_weather/1.0.0.json" ] }
    destination.join("index.json").write(JSON.generate(index))
    destination.join("trust-store.json").write(JSON.generate(publishers: [ { fingerprint: "abc", label: "verified" } ]))
    FileUtils.mkdir_p(destination.join("acme_weather"))
    destination.join("acme_weather/1.0.0.json").write(JSON.generate(registry_entry("acme_weather", "1.0.0", ">= 1.0", "abc")))
    FileUtils.mkdir_p(destination.join(".git"))
  end
end
