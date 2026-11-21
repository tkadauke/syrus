require "aws-sdk-s3"
require "base64"
require "digest"
require "json"

module S3BackupDestination
  class Destination
    include Syrus::Host::BackupDestination

    PART_SIZE = 8 * 1024 * 1024
    CHUNK_SIZE = 64 * 1024
    IDENTITY = "s3_backup_destination:v1"

    class Error < StandardError; end
    class VerificationFailed < Error; end

    def self.upload(artifact, progress: nil, client: default_client)
      bucket = configured_bucket!
      backup_id = artifact.fetch(:id).to_s
      source_checksum = artifact.fetch(:checksum).fetch(:value).to_s
      key = object_key(backup_id)
      io = artifact.fetch(:io)
      existing = existing_reference(client, bucket:, key:, backup_id:, source_checksum:)
      return existing if existing

      content_checksum = digest_io(io)
      response = client.create_multipart_upload(
        bucket:, key:, metadata: {
          "backup-id" => backup_id, "source-sha256" => source_checksum, "content-sha256" => content_checksum
        }
      )
      upload_id = response.upload_id
      parts = []
      digest = Digest::SHA256.new
      bytes = 0
      part_number = 0
      while (body = io.read(PART_SIZE))
        break if body.empty?
        part_number += 1
        digest.update(body)
        bytes += body.bytesize
        uploaded = client.upload_part(bucket:, key:, upload_id:, part_number:, body:)
        parts << { etag: uploaded.etag, part_number: }
        progress&.call(bytes)
      end
      client.complete_multipart_upload(bucket:, key:, upload_id:, multipart_upload: { parts: })
      upload_id = nil
      raise VerificationFailed, "uploaded backup checksum changed while streaming" unless secure_equal?(digest.hexdigest, content_checksum)

      { remote_reference: encode_reference(bucket:, key:), checksum: content_checksum, bytes: }
    rescue StandardError => error
      client&.abort_multipart_upload(bucket:, key:, upload_id:) if upload_id
      raise Error, redacted(error)
    ensure
      io&.respond_to?(:close!) ? io.close! : io&.close
    end

    def self.verify(remote_reference, expected_checksum:, client: default_client)
      reference = decode_reference(remote_reference)
      digest = Digest::SHA256.new
      client.get_object(bucket: reference.fetch("bucket"), key: reference.fetch("key")) do |chunk|
        digest.update(chunk)
      end
      raise VerificationFailed, "remote backup checksum did not match" unless secure_equal?(digest.hexdigest, expected_checksum.to_s)

      { verified: true, checksum: digest.hexdigest }
    rescue VerificationFailed
      raise
    rescue StandardError => error
      raise Error, redacted(error)
    end

    def self.delete(remote_reference, reason:, client: default_client)
      reference = decode_reference(remote_reference)
      client.delete_object(bucket: reference.fetch("bucket"), key: reference.fetch("key"))
      true
    rescue StandardError => error
      raise Error, redacted(error)
    end

    def self.materialize_local(remote_reference, destination:, expected_checksum:, client: default_client)
      reference = decode_reference(remote_reference)
      digest = Digest::SHA256.new
      client.get_object(bucket: reference.fetch("bucket"), key: reference.fetch("key")) do |chunk|
        digest.update(chunk)
        destination.write(chunk)
      end
      destination.flush if destination.respond_to?(:flush)
      unless secure_equal?(digest.hexdigest, expected_checksum.to_s)
        raise VerificationFailed, "materialized backup checksum did not match"
      end
      { checksum: digest.hexdigest }
    rescue VerificationFailed
      raise
    rescue StandardError => error
      raise Error, redacted(error)
    end

    def self.health(client: default_client)
      client.head_bucket(bucket: configured_bucket!)
      { healthy: true, destination: IDENTITY }
    rescue StandardError => error
      { healthy: false, destination: IDENTITY, error: redacted(error) }
    end

    def self.default_client
      access_key_id = ENV["SYRUS_BACKUP_S3_ACCESS_KEY_ID"].presence || raise(Error, "backup access key is not configured")
      secret_access_key = ENV["SYRUS_BACKUP_S3_SECRET_ACCESS_KEY"].presence || raise(Error, "backup secret key is not configured")
      options = {
        region: ENV.fetch("SYRUS_BACKUP_S3_REGION", "us-east-1"),
        force_path_style: ENV["SYRUS_BACKUP_S3_ENDPOINT"].present?,
        access_key_id:, secret_access_key:,
        retry_limit: ENV.fetch("SYRUS_BACKUP_S3_RETRY_LIMIT", "3").to_i.clamp(0, 10)
      }
      options[:endpoint] = ENV["SYRUS_BACKUP_S3_ENDPOINT"] if ENV["SYRUS_BACKUP_S3_ENDPOINT"].present?
      Aws::S3::Client.new(**options)
    end

    def self.configured_bucket! = ENV["SYRUS_BACKUP_S3_BUCKET"].presence || raise(Error, "backup bucket is not configured")
    def self.object_key(backup_id) = [ENV.fetch("SYRUS_BACKUP_S3_PREFIX", "syrus-backups").delete_suffix("/"), "#{backup_id}.tar"].join("/")

    def self.existing_reference(client, bucket:, key:, backup_id:, source_checksum:)
      head = client.head_object(bucket:, key:)
      content_checksum = head.metadata["content-sha256"]
      return unless head.metadata["backup-id"] == backup_id && head.metadata["source-sha256"] == source_checksum &&
        content_checksum.present?

      reference = encode_reference(bucket:, key:)
      digest = Digest::SHA256.new
      client.get_object(bucket:, key:) { |chunk| digest.update(chunk) }
      return unless secure_equal?(digest.hexdigest, content_checksum)

      { remote_reference: reference, checksum: content_checksum, bytes: head.content_length }
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      nil
    end

    def self.encode_reference(bucket:, key:)
      "s3:v1:#{Base64.urlsafe_encode64(JSON.generate(bucket:, key:), padding: false)}"
    end

    def self.decode_reference(value)
      prefix, version, payload = value.to_s.split(":", 3)
      raise Error, "invalid remote backup reference" unless prefix == "s3" && version == "v1" && payload.present?
      JSON.parse(Base64.urlsafe_decode64(payload))
    rescue JSON::ParserError, ArgumentError
      raise Error, "invalid remote backup reference"
    end

    def self.redacted(error)
      error.message.to_s.gsub(%r{https?://\S+}, "[REDACTED_URL]").gsub(/(access[_ -]?key|secret|token)=?\S+/i, "\\1=[REDACTED]").first(1000)
    end

    def self.secure_equal?(left, right)
      left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def self.digest_io(io)
      digest = Digest::SHA256.new
      while (chunk = io.read(CHUNK_SIZE))
        digest.update(chunk)
      end
      io.rewind
      digest.hexdigest
    end

    private_class_method :existing_reference, :encode_reference, :decode_reference, :redacted, :secure_equal?, :digest_io
  end
end
