require "rails_helper"
require "rubygems/package"
require "zlib"

RSpec.describe PluginDesiredState::Publisher do
  class RecordingPluginManifestStorage
    attr_reader :writes

    def initialize
      @objects = {}
      @writes = []
    end

    def upload(key, io, **)
      @writes << key
      @objects[key] = io.read
    end

    def download(key) = @objects.fetch(key)
  end

  let(:service) { RecordingPluginManifestStorage.new }
  let(:body) do
    gemspec = <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "weather"
        spec.version = "2.0.0"
        spec.metadata["requires_syrus"] = ">= 1.0"
        spec.add_dependency "rails", ">= 8.1"
      end
    RUBY
    files = {
      "plugin/weather.gemspec" => gemspec,
      "plugin/lib/weather.rb" => "module Weather; end\n"
    }
    manifest = {
      "format_version" => 1, "name" => "weather", "version" => "2.0.0", "requires_syrus" => ">= 1.0",
      "roles" => [], "extension_points" => [], "routes" => [], "credential_types" => [], "cli_commands" => [],
      "frontend" => {}, "locales" => [], "public_host_apis" => [],
      "files" => files.map { |path, data| { "path" => path, "sha256" => Digest::SHA256.hexdigest(data) } }
    }
    package = { "package.json" => JSON.pretty_generate(manifest) + "\n", **files }
    package["CHECKSUMS.sha256"] = package.sort.map do |path, data|
      "#{Digest::SHA256.hexdigest(data)}  #{path}\n"
    end.join
    StringIO.new.tap do |io|
      Zlib::GzipWriter.wrap(io) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          package.sort.each do |path, data|
            tar.add_file_simple(path, 0o644, data.bytesize) { |file| file.write(data) }
          end
        end
      end
    end.string
  end
  let(:digest) { Digest::SHA256.hexdigest(body) }
  let!(:release) do
    PluginRelease.create!(name: "weather", version: "2.0.0", content_digest: digest,
      source: "registry", trust_label: "verified", publisher_fingerprint: "sha256:#{'a' * 64}", size_bytes: body.bytesize)
  end

  before do
    allow(described_class).to receive(:publish!)
    PluginArtifacts.store!(release, StringIO.new(body))
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release, roles: %w[web worker], fleet_quarantined: true)
    allow(described_class).to receive(:publish!).and_call_original
  end

  it "increments the revision and publishes a signed manifest last" do
    first = JSON.parse(described_class.publish!(service:))
    second = JSON.parse(described_class.publish!(service:))

    expect(second.fetch("revision")).to eq(first.fetch("revision") + 1)
    expect(second.fetch("plugins").sole).to include(
      "name" => "weather", "version" => "2.0.0", "digest" => digest, "size" => body.bytesize,
      "trust_label" => "verified", "publisher_fingerprint" => "sha256:#{'a' * 64}",
      "roles" => %w[web worker], "fleet_quarantined" => true
    )
    expect(service.writes.last(2)).to eq([
      PluginDesiredState::Publisher::SIGNATURE_KEY,
      PluginDesiredState::Publisher::MANIFEST_KEY
    ])
  end

  it "produces a signature that verifies and rejects tampering" do
    manifest = described_class.publish!(service:)
    signature = Base64.strict_decode64(service.download(described_class::SIGNATURE_KEY))
    verify_key = Ed25519::VerifyKey.new(Base64.strict_decode64(PluginDesiredState::SigningKey.current.public_key))

    expect { verify_key.verify(signature, manifest) }.not_to raise_error
    expect { verify_key.verify(signature, "#{manifest} ") }.to raise_error(Ed25519::VerifyError)
  end
end
