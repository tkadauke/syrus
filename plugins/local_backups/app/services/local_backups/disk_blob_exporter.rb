require "base64"
require "digest"

module LocalBackups
  class DiskBlobExporter
    class InvalidBlob < StandardError; end

    Entry = Data.define(:id, :key, :byte_size, :content_type, :source_checksum, :bundle_checksum, :relative_path)

    DEFAULT_CONCURRENCY = 4

    def initialize(service: ActiveStorage::Blob.service, concurrency: ENV.fetch("SYRUS_BACKUP_OBJECT_CONCURRENCY", DEFAULT_CONCURRENCY))
      @service = service
      @concurrency = Integer(concurrency)
      raise ArgumentError, "backup object concurrency must be positive" unless @concurrency.positive?
    end

    def export(selection, destination)
      queue = Queue.new
      selection.each_with_index { |blob, index| queue << [index, blob] }
      results = Array.new(selection.length)
      failures = Queue.new
      workers = [@concurrency, selection.length].min.times.map do
        Thread.new do
          loop do
            index, blob = queue.pop(true)
            results[index] = export_one(blob, destination)
          rescue ThreadError
            break
          rescue StandardError => error
            failures << error
            break
          end
        end
      end
      workers.each(&:join)
      raise failures.pop unless failures.empty?

      results
    end

    private

    def export_one(blob, destination)
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
