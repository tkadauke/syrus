require "rails_helper"
require "rubygems/package"
require "tmpdir"

RSpec.describe RuntimeImages::WorkerCache::OciArchive do
  def sha(bytes) = "sha256:#{Digest::SHA256.hexdigest(bytes)}"

  def write_archive(dir, files)
    path = File.join(dir, "image.tar")
    File.open(path, "wb") do |io|
      Gem::Package::TarWriter.new(io) do |tar|
        files.each { |name, content| tar.add_file_simple(name, 0o644, content.bytesize) { |f| f.write(content) } }
      end
    end
    path
  end

  def blob_path(bytes) = "blobs/sha256/#{sha(bytes).split(':').last}"

  let(:config) { '{"os":"linux"}' }
  let(:layer) { "layer-bytes" }
  let(:manifest) do
    JSON.generate("mediaType" => "application/vnd.oci.image.manifest.v1+json",
                  "config" => { "digest" => sha(config) }, "layers" => [ { "digest" => sha(layer) } ])
  end
  let(:files) do
    { "index.json" => JSON.generate("manifests" => [ { "digest" => sha(manifest), "mediaType" => "application/vnd.oci.image.manifest.v1+json" } ]),
      blob_path(manifest) => manifest, blob_path(config) => config, blob_path(layer) => layer }
  end

  it "returns the manifest and the blobs it references" do
    Dir.mktmpdir do |dir|
      payload = described_class.read(write_archive(dir, files), platform: "linux/amd64")

      expect(payload[:manifest]).to eq(manifest)
      expect(payload[:blobs]).to eq(sha(config) => config, sha(layer) => layer)
    end
  end

  it "selects the requested platform from an index" do
    other = JSON.generate("layers" => [], "config" => { "digest" => sha(config) }, "x" => 1)
    index = { "manifests" => [
      { "digest" => sha(other), "platform" => { "os" => "linux", "architecture" => "arm64" } },
      { "digest" => sha(manifest), "platform" => { "os" => "linux", "architecture" => "amd64" } }
    ] }
    Dir.mktmpdir do |dir|
      archive = write_archive(dir, files.merge("index.json" => JSON.generate(index), blob_path(other) => other))
      expect(described_class.read(archive, platform: "linux/amd64")[:manifest]).to eq(manifest)
      expect(described_class.read(archive, platform: "linux/arm64")[:manifest]).to eq(other)
      expect { described_class.read(archive, platform: "linux/s390x") }.to raise_error(RuntimeImages::WorkerCache::EngineError, /no linux\/s390x/)
    end
  end

  it "rejects an archive that is not an OCI layout" do
    Dir.mktmpdir do |dir|
      expect { described_class.read(write_archive(dir, "manifest.json" => "[]"), platform: "linux/amd64") }
        .to raise_error(RuntimeImages::WorkerCache::EngineError, /not an OCI layout/)
    end
  end

  it "rejects a blob whose bytes do not match its digest" do
    Dir.mktmpdir do |dir|
      archive = write_archive(dir, files.merge(blob_path(layer) => "tampered"))
      expect { described_class.read(archive, platform: "linux/amd64") }
        .to raise_error(RuntimeImages::WorkerCache::EngineError, /does not match its digest/)
    end
  end
end
