require "digest"
require "json"
require "open3"
require "openssl"
require "active_storage/service/s3_service"

# Streams a prepared workflow workspace straight from `tar` through a
# low-cost gzip compressor and into the configured ActiveStorage service,
# without ever materializing the archive on local disk. When the service
# is S3-backed, bytes are pushed through a genuine multipart upload (via
# the AWS SDK's streaming uploader) so an incomplete upload can be aborted
# server-side; other services (e.g. Disk, used in dev/test) stream the
# same pipeline through their own #upload.
class PreparedWorkspaceArchive
  class ArchiveTooLargeError < StandardError; end
  class ArchivePipelineError < StandardError; end

  CONTENT_TYPE = "application/gzip".freeze
  MAX_BYTES = 1.gigabyte
  COMPRESSION_LEVEL = 1
  READ_CHUNK_SIZE = 1.megabyte

  def self.prepare_fingerprint_for(plan)
    Digest::SHA256.hexdigest(JSON.generate(
      "source" => plan.source,
      "note" => plan.note,
      "guessed" => plan.guessed?,
      "commands" => plan.commands
    ))
  end

  def self.publish!(...)
    new(...).publish!
  end

  def self.metadata(workflow:, snapshot:, plan:)
    {
      "workflow_id" => workflow.id,
      "source_snapshot_id" => snapshot.id,
      "source_sha" => snapshot.source_sha,
      "source_ref" => snapshot.source_ref,
      "tree_sha" => snapshot.tree_sha,
      "prepare_fingerprint" => prepare_fingerprint_for(plan),
      "prepare_source" => plan.source,
      "max_bytes" => MAX_BYTES,
      "compressor" => (pigz_available? ? "pigz" : "gzip"),
      "compression_level" => COMPRESSION_LEVEL,
      "uploaded_at" => Time.current.iso8601
    }.compact
  end

  # Memoized for the life of the process: re-shelling out to check for
  # pigz on every publish would defeat the point of a cheap compressor.
  def self.pigz_available?
    return @pigz_available if defined?(@pigz_available)

    @pigz_available = system("pigz", "--version", out: File::NULL, err: File::NULL) == true
  end

  def initialize(workflow:, snapshot:, step:, path:, plan: nil, log: nil)
    @workflow = workflow
    @snapshot = snapshot
    @step = step
    @path = Pathname.new(path)
    @plan = plan || RepoPrepPlan.for(@path)
    @log = log
  end

  def publish!
    return false if already_published?

    service = nil
    key = nil
    WorkerIoGate.synchronize do
      return false if already_published?

      service = ActiveStorage::Blob.service
      key = ActiveStorage::Blob.generate_unique_secure_token
      source = stream_archive!(service: service, key: key)

      blob = ActiveStorage::Blob.create_before_direct_upload!(
        key: key,
        filename: filename,
        byte_size: source.bytes,
        checksum: source.checksum,
        content_type: CONTENT_TYPE,
        metadata: metadata.merge("sha256" => source.sha256),
        service_name: service.name
      )
      @snapshot.prepared_workspace_archive.attach(blob)
      log("uploaded prepared workspace archive for snapshot ##{@snapshot.id} " \
        "(#{source.bytes} bytes, #{self.class.pigz_available? ? "pigz" : "gzip"})")
      true
    end
  rescue ArchiveTooLargeError => e
    log("prepared archive upload skipped: #{e.message}")
    cleanup_partial_upload!(service, key)
    false
  rescue StandardError => e
    log("prepared archive upload failed; continuing without archive: #{e.class}: #{e.message}")
    cleanup_partial_upload!(service, key)
    false
  end

  def metadata
    self.class.metadata(workflow: @workflow, snapshot: @snapshot, plan: @plan)
  end

  private

  def filename
    "workflow-source-snapshot-#{@snapshot.id}-prepared.tar.gz"
  end

  def already_published?
    @snapshot.prepared_workspace_archive.attached? &&
      prepared_archive_metadata_matches?(@snapshot.prepared_workspace_archive.blob.metadata)
  end

  def prepared_archive_metadata_matches?(metadata)
    metadata.to_h.slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha",
      "prepare_fingerprint"
    ) == self.metadata.slice(
      "workflow_id",
      "source_snapshot_id",
      "source_sha",
      "prepare_fingerprint"
    )
  end

  # Runs `tar | gzip -1` (or `tar | pigz -1`) as a pipeline and streams its
  # stdout straight into the destination service, tracking size and
  # integrity digests as bytes flow through -- no intermediate archive file.
  def stream_archive!(service:, key:)
    stdout, wait_threads = archive_pipeline
    stdout.binmode
    source = StreamingSource.new(stdout, max_bytes: MAX_BYTES)

    begin
      if service.is_a?(ActiveStorage::Service::S3Service)
        upload_via_s3_multipart(service: service, key: key, source: source)
      else
        service.upload(key, source, checksum: nil, content_type: CONTENT_TYPE)
      end
    ensure
      stdout.close unless stdout.closed?
    end

    verify_pipeline!(wait_threads)
    source
  end

  def archive_pipeline
    Open3.pipeline_r(
      ["tar", "--exclude=./.syrus/immutable-checkouts", "-cf", "-", "-C", @path.to_s, "."],
      compressor_command
    )
  end

  def compressor_command
    if self.class.pigz_available?
      ["pigz", "-#{COMPRESSION_LEVEL}", "-c"]
    else
      ["gzip", "-#{COMPRESSION_LEVEL}", "-c"]
    end
  end

  def upload_via_s3_multipart(service:, key:, source:)
    options = { content_type: CONTENT_TYPE, **service.upload_options }

    if defined?(Aws::S3::TransferManager)
      Aws::S3::TransferManager.new(client: service.client.client).upload_stream(
        bucket: service.bucket.name, key: key, **options
      ) { |write_stream| copy_source_into(source, write_stream) }
    else
      service.bucket.object(key).upload_stream(**options) { |write_stream| copy_source_into(source, write_stream) }
    end
  rescue Aws::S3::MultipartUploadError => e
    # The uploader aborts the multipart upload itself before re-raising;
    # surface our own error (size limit) when that's what caused it.
    raise e.errors.find { |err| err.is_a?(ArchiveTooLargeError) } || e
  end

  def copy_source_into(source, write_stream)
    write_stream.binmode
    while (chunk = source.read(READ_CHUNK_SIZE))
      write_stream.write(chunk)
    end
  end

  def verify_pipeline!(wait_threads)
    statuses = wait_threads.map(&:value)
    return if statuses.all?(&:success?)

    raise ArchivePipelineError, "archive pipeline failed: " \
      "#{statuses.map { |status| "pid #{status.pid} exited #{status.exitstatus}" }.join(", ")}"
  end

  def cleanup_partial_upload!(service, key)
    service&.delete(key) if key
  rescue StandardError
    nil
  end

  def log(message)
    @log&.call("[prepared_workspace_archive] #{message}", kind: "system")
  end

  # IO-like wrapper around the tar|compressor pipeline's stdout: tracks
  # bytes read and integrity digests in a single pass, and raises before
  # yielding another byte once the configured limit is exceeded, so the
  # upload aborts instead of ever buffering (or storing) an oversized
  # archive.
  class StreamingSource
    def initialize(io, max_bytes:)
      @io = io
      @max_bytes = max_bytes
      @bytes = 0
      @md5 = OpenSSL::Digest::MD5.new
      @sha256 = OpenSSL::Digest::SHA256.new
    end

    attr_reader :bytes

    def read(length = READ_CHUNK_SIZE, outbuf = nil)
      chunk = @io.read(length, outbuf)
      return nil if chunk.nil?

      @bytes += chunk.bytesize
      if @bytes > @max_bytes
        raise ArchiveTooLargeError, "#{@bytes} bytes exceeds #{@max_bytes} byte limit"
      end

      @md5 << chunk
      @sha256 << chunk
      chunk
    end

    def checksum
      @md5.base64digest
    end

    def sha256
      @sha256.hexdigest
    end
  end
end
