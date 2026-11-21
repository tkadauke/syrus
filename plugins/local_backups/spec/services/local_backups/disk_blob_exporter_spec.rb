require "rails_helper"
require_relative "../../support/resolved_tmpdir"

RSpec.describe LocalBackups::DiskBlobExporter do
  let(:service) { ActiveStorage::Blob.service }
  let(:key) { "ab12#{SecureRandom.hex(12)}" }
  let(:content) { "recover me" }
  let(:selection) do
    [{
      "id" => 42,
      "key" => key,
      "byte_size" => content.bytesize,
      "content_type" => "text/plain",
      "checksum" => Digest::MD5.base64digest(content)
    }]
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @destination = Pathname.new(directory)
      example.run
    end
  ensure
    service.delete(key)
  end

  it "streams a selected blob to its partitioned path with verified checksums" do
    service.upload(key, StringIO.new(content))

    entry = described_class.new(service:).export(selection, @destination).sole

    expect(entry.relative_path).to eq("blobs/ab/12/#{key}")
    expect(@destination.join(entry.relative_path).binread).to eq(content)
    expect(entry.bundle_checksum).to eq(Digest::SHA256.hexdigest(content))
    expect(entry.source_checksum).to eq(Digest::MD5.base64digest(content))
  end

  it "fails when a selected blob is missing" do
    expect { described_class.new(service:).export(selection, @destination) }
      .to raise_error(described_class::InvalidBlob, /blob 42 is missing/)
  end

  it "fails when streamed bytes do not match the source checksum" do
    service.upload(key, StringIO.new("tampered!!"))

    expect { described_class.new(service:).export(selection, @destination) }
      .to raise_error(described_class::InvalidBlob, /failed source checksum validation/)
  end

  it "streams through a non-Disk service with bounded concurrency" do
    active = 0
    maximum = 0
    lock = Mutex.new
    remote = Object.new
    def remote.download(*) = nil
    allow(remote).to receive(:download) do |_object_key, &block|
      lock.synchronize { active += 1; maximum = [maximum, active].max }
      sleep 0.01
      block.call(content)
    ensure
      lock.synchronize { active -= 1 }
    end
    objects = 6.times.map { |index| selection.first.merge("id" => index, "key" => "#{index}x#{key}") }

    entries = described_class.new(service: remote, concurrency: 2).export(objects, @destination)

    expect(entries.map(&:id)).to eq((0...6).to_a)
    expect(maximum).to be_between(1, 2)
    expect(entries).to all(have_attributes(bundle_checksum: Digest::SHA256.hexdigest(content)))
  end
end
