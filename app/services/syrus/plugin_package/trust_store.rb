require "json"
require "set"
require "fileutils"
require "tempfile"

module Syrus
  module PluginPackage
    class TrustStore
      LABELS = %w[official verified community].freeze
      Publisher = Data.define(:fingerprint, :label, :prefix)

      attr_reader :revoked_keys, :revoked_releases

      def self.cache_path
        WorkflowWorkspace.data_root.join("plugin-registry", "trust-store.json")
      end

      def self.cached(path: cache_path, plugin_registry: nil)
        with_cache_lock(path) { reconcile_pending_or_load(path, plugin_registry:) }
      end

      def self.for_release(release)
        return cached unless release.plugin_registry

        PluginRegistryClient.new(source: release.plugin_registry).cached_trust_store
      end

      def self.cache!(data, path: cache_path, plugin_registry: nil)
        store = data.is_a?(self) ? data : new(data)
        with_cache_lock(path) do
          write_pending(store, path:)
          reconcile_pending_or_load(path, plugin_registry:)
        end
      end

      def self.reconcile_pending_or_load(path, plugin_registry: nil)
        pending_path = reconciliation_path(path)
        if File.exist?(pending_path)
          store = load(pending_path)
          RevocationReconciler.new(store, plugin_registry:).call
          File.rename(pending_path, path)
          return store
        end

        return new({}) unless File.exist?(path)

        load(path)
      end

      def self.with_cache_lock(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def self.reconciliation_path(path = cache_path) = Pathname.new("#{path}.pending")

      def self.write_pending(store, path: cache_path)
        pending_path = reconciliation_path(path)
        FileUtils.mkdir_p(File.dirname(path))
        tempfile = Tempfile.new([ "trust-store", ".json" ], File.dirname(path))
        tempfile.write(JSON.pretty_generate(store.as_json))
        tempfile.write("\n")
        tempfile.flush
        tempfile.fsync
        tempfile.close
        File.rename(tempfile.path, pending_path)
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
          [ fingerprint, Publisher.new(fingerprint:, label:, prefix: publisher["prefix"]) ]
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
          "publishers" => @publishers.values.map do |publisher|
            { "fingerprint" => publisher.fingerprint, "label" => publisher.label, "prefix" => publisher.prefix }.compact
          end,
          "revoked_keys" => revoked_keys.to_a.sort,
          "revoked_releases" => revoked_releases
        }
      end

      def with_official_capped
        data = as_json
        data["publishers"].each { |publisher| publisher["label"] = "verified" if publisher["label"] == "official" }
        self.class.new(data)
      end
    end
  end
end
