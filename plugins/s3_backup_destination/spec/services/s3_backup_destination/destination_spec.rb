require "rails_helper"
require "stringio"

RSpec.describe S3BackupDestination::Destination do
  class MemoryS3Client
    Head = Data.define(:metadata, :content_length)
    Upload = Data.define(:upload_id)
    Part = Data.define(:etag)
    attr_reader :deleted, :objects, :multipart_uploads

    def initialize
      @objects = {}
      @uploads = {}
      @deleted = []
      @multipart_uploads = 0
    end

    def head_object(bucket:, key:)
      object = @objects.fetch([bucket, key]) { raise Aws::S3::Errors::NotFound.new(nil, "missing") }
      Head.new(metadata: object.fetch(:metadata), content_length: object.fetch(:body).bytesize)
    end

    def create_multipart_upload(bucket:, key:, metadata:)
      @multipart_uploads += 1
      @uploads["upload-1"] = { bucket:, key:, metadata:, parts: {} }
      Upload.new(upload_id: "upload-1")
    end

    def upload_part(bucket:, key:, upload_id:, part_number:, body:)
      @uploads.fetch(upload_id).fetch(:parts)[part_number] = body
      Part.new(etag: "etag-#{part_number}")
    end

    def complete_multipart_upload(bucket:, key:, upload_id:, multipart_upload:)
      upload = @uploads.delete(upload_id)
      @objects[[bucket, key]] = { metadata: upload.fetch(:metadata), body: upload.fetch(:parts).sort.to_h.values.join }
    end

    def abort_multipart_upload(bucket:, key:, upload_id:) = @uploads.delete(upload_id)
    def get_object(bucket:, key:) = @objects.fetch([bucket, key]).fetch(:body).scan(/.{1,7}/m) { |chunk| yield chunk }

    def delete_object(bucket:, key:)
      @deleted << [bucket, key]
      @objects.delete([bucket, key])
    end

    def head_bucket(bucket:) = true
  end

  let(:client) { MemoryS3Client.new }

  around do |example|
    previous_bucket = ENV["SYRUS_BACKUP_S3_BUCKET"]
    previous_prefix = ENV["SYRUS_BACKUP_S3_PREFIX"]
    ENV["SYRUS_BACKUP_S3_BUCKET"] = "recovery"
    ENV["SYRUS_BACKUP_S3_PREFIX"] = "sealed"
    example.run
  ensure
    previous_bucket.nil? ? ENV.delete("SYRUS_BACKUP_S3_BUCKET") : ENV["SYRUS_BACKUP_S3_BUCKET"] = previous_bucket
    previous_prefix.nil? ? ENV.delete("SYRUS_BACKUP_S3_PREFIX") : ENV["SYRUS_BACKUP_S3_PREFIX"] = previous_prefix
  end

  it "streams, verifies, reuses, materializes, and deletes an opaque remote artifact" do
    body = "portable recovery bundle" * 100
    first = described_class.upload(
      { id: "backup-uuid", checksum: { value: "source-checksum" }, io: StringIO.new(body) }, client:
    )
    expect(first.fetch(:remote_reference)).to start_with("s3:v1:")
    expect(first.fetch(:checksum)).to eq(Digest::SHA256.hexdigest(body))

    reused = described_class.upload(
      { id: "backup-uuid", checksum: { value: "source-checksum" }, io: StringIO.new(body) }, client:
    )
    expect(reused.fetch(:checksum)).to eq(first.fetch(:checksum))
    expect(client.multipart_uploads).to eq(1)

    client.objects.fetch(["recovery", "sealed/backup-uuid.tar"])[:body] = "corrupt"
    repaired = described_class.upload(
      { id: "backup-uuid", checksum: { value: "source-checksum" }, io: StringIO.new(body) }, client:
    )
    expect(repaired.fetch(:checksum)).to eq(first.fetch(:checksum))
    expect(client.multipart_uploads).to eq(2)
    expect(described_class.verify(first.fetch(:remote_reference), expected_checksum: first.fetch(:checksum), client:)).to include(verified: true)

    destination = StringIO.new
    result = described_class.materialize_local(
      first.fetch(:remote_reference), destination:, expected_checksum: first.fetch(:checksum), client:
    )
    expect(destination.string).to eq(body)
    expect(result.fetch(:checksum)).to eq(first.fetch(:checksum))

    expect(described_class.delete(first.fetch(:remote_reference), reason: "retention", client:)).to be(true)
    expect(client.deleted).to eq([["recovery", "sealed/backup-uuid.tar"]])
  end

  it "rejects corrupt remote content and redacts endpoint failures" do
    uploaded = described_class.upload(
      { id: "backup-uuid", checksum: { value: "source-checksum" }, io: StringIO.new("content") }, client:
    )
    expect do
      described_class.verify(uploaded.fetch(:remote_reference), expected_checksum: "0" * 64, client:)
    end.to raise_error(described_class::VerificationFailed, /did not match/)

    failing = Object.new
    def failing.head_bucket(bucket:) = raise("request https://user:secret@example.test/?token=private failed")
    health = described_class.health(client: failing)
    expect(health).to include(healthy: false)
    expect(health.fetch(:error)).not_to include("example.test", "private")
  end
end
