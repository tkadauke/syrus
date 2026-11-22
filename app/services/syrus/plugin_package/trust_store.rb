require "json"
require "set"
require "fileutils"
require "tempfile"

module Syrus
  module PluginPackage
    class TrustStore
      LABELS = %w[official verified community].freeze
      Publisher = Data.define(:fingerprint, :label)

      attr_reader :revoked_keys, :revoked_releases

      def self.cache_path
        WorkflowWorkspace.data_root.join("plugin-registry", "trust-store.json")
      end

      def self.cached(path: cache_path)
        return new({}) unless File.exist?(path)

        load(path)
      end

      def self.cache!(data, path: cache_path)
        store = data.is_a?(self) ? data : new(data)
        FileUtils.mkdir_p(File.dirname(path))
        tempfile = Tempfile.new([ "trust-store", ".json" ], File.dirname(path))
        tempfile.write(JSON.pretty_generate(store.as_json))
        tempfile.write("\n")
        tempfile.flush
        tempfile.fsync
        tempfile.close
        File.rename(tempfile.path, path)
        RevocationReconciler.new(store).call
        store
      ensure
        tempfile&.close!
      end

      def self.load(source)
        data = source.respond_to?(:read) ? JSON.parse(source.read) : JSON.parse(File.read(source))
        new(data)
      end

      def initialize(data)
        @publishers = Array(data.fetch("publishers", [])).to_h do |publisher|
          fingerprint = publisher.fetch("fingerprint").downcase
          label = publisher.fetch("label")
          raise ArgumentError, "invalid publisher trust label: #{label}" unless LABELS.include?(label)
          [ fingerprint, Publisher.new(fingerprint:, label:) ]
        end
        @revoked_keys = Array(data.fetch("revoked_keys", [])).map(&:downcase).to_set
        @revoked_releases = Array(data.fetch("revoked_releases", []))
      end

      def publisher(fingerprint) = @publishers[fingerprint.to_s.downcase]

      def revoked_release?(name:, version:, digest:)
        revoked_releases.any? do |release|
          release["name"] == name && release["version"] == version &&
            (release["digest"].nil? || release["digest"] == digest)
        end
      end

      def revoked?(release)
        key_revoked = release.publisher_key_fingerprint.present? && revoked_keys.include?(release.publisher_key_fingerprint.downcase)
        key_revoked || revoked_release?(name: release.name, version: release.version, digest: release.content_digest)
      end

      def as_json(*)
        {
          "publishers" => @publishers.values.map { |publisher| { "fingerprint" => publisher.fingerprint, "label" => publisher.label } },
          "revoked_keys" => revoked_keys.to_a.sort,
          "revoked_releases" => revoked_releases
        }
      end
    end
  end
end
