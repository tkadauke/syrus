require "json"
require "digest"
require "rubygems/package"

module RuntimeImages
  class WorkerCache
    # Reads the `docker save` OCI layout into the payload the OCI registry
    # provider publishes: the platform's image manifest plus the config and
    # layer blobs it references. Every blob is verified against its digest
    # before it is returned.
    module OciArchive
      INDEX_TYPES = %w[application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json].freeze

      module_function

      def read(path, platform:)
        entries = {}
        File.open(path, "rb") do |file|
          Gem::Package::TarReader.new(file) do |tar|
            tar.each { |entry| entries[entry.full_name.delete_prefix("./")] = entry.read if entry.file? }
          end
        end
        raise EngineError, "image archive is not an OCI layout (no index.json)" unless entries.key?("index.json")

        manifest_bytes = select_manifest(entries, JSON.parse(entries.fetch("index.json")), platform)
        manifest = JSON.parse(manifest_bytes)
        referenced = [ manifest.dig("config", "digest"), *Array(manifest["layers"]).map { |layer| layer["digest"] } ].compact
        blobs = referenced.uniq.to_h { |digest| [ digest, blob(entries, digest) ] }
        { manifest: manifest_bytes, blobs: blobs }
      rescue JSON::ParserError, Gem::Package::TarInvalidError => e
        raise EngineError, "image archive could not be read: #{e.message}"
      end

      def select_manifest(entries, index, platform)
        os, arch, variant = platform.to_s.split("/")
        candidates = Array(index["manifests"])
        match = candidates.find do |descriptor|
          p = descriptor["platform"] || {}
          p["os"] == os && p["architecture"] == arch && (variant.nil? || p["variant"] == variant)
        end
        # A single-image layout has no platform on its descriptor; the image
        # config below is checked instead.
        match ||= candidates.first if candidates.size == 1 && candidates.first["platform"].nil?
        raise EngineError, "image archive has no #{platform} manifest" unless match

        bytes = blob(entries, match.fetch("digest"))
        return bytes unless INDEX_TYPES.include?(match["mediaType"]) || INDEX_TYPES.include?(JSON.parse(bytes)["mediaType"])

        select_manifest(entries, JSON.parse(bytes), platform)
      end

      def blob(entries, digest)
        algorithm, hex = digest.to_s.split(":", 2)
        bytes = entries["blobs/#{algorithm}/#{hex}"] or raise EngineError, "image archive is missing blob #{digest}"
        raise EngineError, "image archive blob #{digest} does not match its digest" unless "sha256:#{Digest::SHA256.hexdigest(bytes)}" == digest
        bytes
      end
    end
  end
end
