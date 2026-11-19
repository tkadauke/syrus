require "base64"
require "digest"

module LocalBackups
  class DiskBlobExporter
    class InvalidBlob < StandardError; end

    Entry = Data.define(:id, :key, :byte_size, :content_type, :source_checksum, :bundle_checksum, :relative_path)

    def initialize(service: ActiveStorage::Blob.service)
      @service = service
      raise ArgumentError, "local backup creation requires Disk Active Storage" unless service.is_a?(ActiveStorage::Service::DiskService)
    end

    def export(selection, destination)
      selection.map do |blob|
        relative = Pathname.new("blobs").join(partitioned(blob.fetch("key")))
        target = destination.join(relative)
        target.dirname.mkpath
        sha256 = Digest::SHA256.new
        md5 = Digest::MD5.new
        bytes = 0

        File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          @service.download(blob.fetch("key")) do |chunk|
            file.write(chunk)
            sha256.update(chunk)
            md5.update(chunk)
            bytes += chunk.bytesize
          end
          file.flush
          file.fsync
        end

        validate!(blob, bytes:, md5:)
        Entry.new(
          id: blob.fetch("id"), key: blob.fetch("key"), byte_size: bytes,
          content_type: blob["content_type"], source_checksum: blob["checksum"],
          bundle_checksum: sha256.hexdigest, relative_path: relative.to_s
        )
      rescue ActiveStorage::FileNotFoundError, Errno::ENOENT => e
        raise InvalidBlob, "blob #{blob.fetch('id')} is missing: #{e.class}"
      end
    end

    private

    def validate!(blob, bytes:, md5:)
      raise InvalidBlob, "blob #{blob.fetch('id')} is truncated" unless bytes == blob.fetch("byte_size")
      return if blob["checksum"].blank? || Base64.strict_encode64(md5.digest) == blob["checksum"]

      raise InvalidBlob, "blob #{blob.fetch('id')} failed source checksum validation"
    end

    def partitioned(key)
      Pathname.new(key[0, 2]).join(key[2, 2], key)
    end
  end
end
