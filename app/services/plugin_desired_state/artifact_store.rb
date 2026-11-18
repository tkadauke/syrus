require "digest"

module PluginDesiredState
  class ArtifactStore
    PREFIX = "plugins/artifacts/"

    def initialize(release, service: ActiveStorage::Blob.service)
      @release = release
      @service = service
    end

    def store!(io)
      tempfile = Tempfile.new([ "plugin-artifact", ".archive" ], binmode: true)
      digest = Digest::SHA256.new
      size = 0
      while (chunk = io.read(64.kilobytes))
        digest.update(chunk)
        tempfile.write(chunk)
        size += chunk.bytesize
      end
      actual = digest.hexdigest
      raise DigestMismatch, "expected #{@release.content_digest}, got #{actual}" unless ActiveSupport::SecurityUtils.secure_compare(@release.content_digest, actual)
      raise DigestMismatch, "expected #{@release.size_bytes} bytes, got #{size}" unless @release.size_bytes == size

      if (existing = ActiveStorage::Blob.find_by(key: "#{PREFIX}#{actual}"))
        raise MissingStoredArtifact, "blob record exists but artifact is missing for #{actual}" unless @service.exist?(existing.key)

        @release.archive.attach(existing)
        return existing
      end

      tempfile.rewind
      blob = ActiveStorage::Blob.create_and_upload!(
        io: tempfile,
        filename: "#{@release.name}-#{@release.version}.archive",
        content_type: "application/octet-stream",
        key: "#{PREFIX}#{actual}",
        service_name: @service.name,
        identify: false
      )
      @release.archive.attach(blob)
      blob
    ensure
      tempfile&.close!
    end

    class DigestMismatch < StandardError; end
    class MissingStoredArtifact < StandardError; end
  end
end
