require "rails_helper"

RSpec.describe PluginRegistryPackageFetcher do
  before do
    allow(SsrfGuard).to receive(:safe_host?).and_call_original
    allow(SsrfGuard).to receive(:safe_host?).with("registry.example.test").and_return(true)
  end

  it "resolves a versioned registry entry and downloads its package and signature" do
    root = Pathname.new(Dir.mktmpdir)
    FileUtils.mkdir_p(root.join("weather"))
    File.write(root.join("weather", "1.2.3.json"), JSON.generate(
      "name" => "weather", "version" => "1.2.3",
      "artifact_url" => "https://registry.example.test/weather-1.2.3.tar.gz",
      "signature_url" => "https://registry.example.test/weather-1.2.3.tar.gz.sig"
    ))
    stub_request(:get, "https://registry.example.test/weather-1.2.3.tar.gz").to_return(body: "archive")
    stub_request(:get, "https://registry.example.test/weather-1.2.3.tar.gz.sig").to_return(body: "signature")

    package = described_class.new(index_root: root).fetch(name: "weather", version: "1.2.3")

    expect(package.archive.read).to eq("archive")
    expect(package.signature).to eq("signature")
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  it "selects the newest indexed version when none is requested" do
    root = Pathname.new(Dir.mktmpdir)
    FileUtils.mkdir_p(root.join("weather"))
    %w[1.9.0 1.10.0].each do |version|
      File.write(root.join("weather", "#{version}.json"), JSON.generate(
        "name" => "weather", "version" => version,
        "artifact_url" => "https://registry.example.test/#{version}.tar.gz",
        "signature_url" => "https://registry.example.test/#{version}.sig"
      ))
    end
    stub_request(:get, "https://registry.example.test/1.10.0.tar.gz").to_return(body: "newest")
    stub_request(:get, "https://registry.example.test/1.10.0.sig").to_return(body: "signature")

    expect(described_class.new(index_root: root).fetch(name: "weather").archive.read).to eq("newest")
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  it "rejects non-HTTPS artifact locations" do
    root = Pathname.new(Dir.mktmpdir)
    FileUtils.mkdir_p(root.join("weather"))
    File.write(root.join("weather", "1.0.0.json"), JSON.generate(
      "name" => "weather", "version" => "1.0.0",
      "artifact_url" => "http://registry.example.test/archive.tar.gz",
      "signature_url" => "https://registry.example.test/archive.sig"
    ))

    expect { described_class.new(index_root: root).fetch(name: "weather", version: "1.0.0") }
      .to raise_error(described_class::Error, /must use HTTPS/)
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  it "rejects registry artifact hosts that resolve to private addresses" do
    root = Pathname.new(Dir.mktmpdir)
    FileUtils.mkdir_p(root.join("weather"))
    File.write(root.join("weather", "1.0.0.json"), JSON.generate(
      "name" => "weather", "version" => "1.0.0",
      "artifact_url" => "https://127.0.0.1/archive.tar.gz",
      "signature_url" => "https://registry.example.test/archive.sig"
    ))

    expect { described_class.new(index_root: root).fetch(name: "weather", version: "1.0.0") }
      .to raise_error(described_class::Error, /host is not permitted/)
    expect(WebMock).not_to have_requested(:get, "https://127.0.0.1/archive.tar.gz")
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  it "stops reading a registry download when its body exceeds the limit" do
    stub_request(:get, "https://registry.example.test/archive.tar.gz").to_return(body: "oversized")

    expect {
      described_class.new.send(:download, "https://registry.example.test/archive.tar.gz", limit: 4)
    }.to raise_error(described_class::Error, /too large/)
  end

  it "rejects a downloaded package whose digest does not match the index" do
    root = Pathname.new(Dir.mktmpdir)
    FileUtils.mkdir_p(root.join("weather"))
    File.write(root.join("weather", "1.0.0.json"), JSON.generate(
      "name" => "weather", "version" => "1.0.0",
      "package_url" => "https://registry.example.test/archive.tar.gz", "package_digest" => "0" * 64,
      "signature_url" => "https://registry.example.test/archive.sig"
    ))
    stub_request(:get, "https://registry.example.test/archive.tar.gz").to_return(body: "tampered")

    expect {
      described_class.new(index_root: root).fetch(name: "weather", version: "1.0.0")
    }.to raise_error(described_class::Error, /digest does not match/)
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end

  it "activates registry trust only after both downloads succeed" do
    root = Pathname.new(Dir.mktmpdir)
    FileUtils.mkdir_p(root.join("acme_weather"))
    File.write(root.join("acme_weather", "1.0.0.json"), JSON.generate(
      "name" => "acme_weather", "version" => "1.0.0",
      "package_url" => "https://registry.example.test/archive.tar.gz",
      "package_digest" => Digest::SHA256.hexdigest("archive"),
      "signature_url" => "https://registry.example.test/archive.sig"
    ))
    entry = instance_double(PluginRegistryClient::Entry, version: "1.0.0")
    client = instance_double(PluginRegistryClient)
    allow(client).to receive(:entry).with(name: "acme_weather", version: "1.0.0").and_return(entry)
    allow(client).to receive(:activate_trust_store!)
    stub_request(:get, "https://registry.example.test/archive.tar.gz").to_return(body: "archive")
    stub_request(:get, "https://registry.example.test/archive.sig").to_return(body: "signature")

    described_class.new(index_root: root, client:).fetch(name: "acme_weather", version: "1.0.0")

    expect(client).to have_received(:activate_trust_store!).once
  ensure
    FileUtils.remove_entry(root) if root&.exist?
  end
end
