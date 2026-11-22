require "rails_helper"

RSpec.describe PluginRegistryPackageFetcher do
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
end
