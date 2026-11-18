require "digest"
require "syrus/host"
require "syrus/plugin_host_surface"

module Syrus
  class PluginHostSurface
    class Scanner
      Finding = Data.define(:constant, :tier, :path, :line)
      Result = Data.define(:public, :legacy, :unlisted, :minimum_syrus_version, :content_hash, :error) do
        def violations? = unlisted.any?
        def warnings? = legacy.any?
        def findings = [ *public, *legacy, *unlisted ]
      end

      def initialize(directory, surface: PluginHostSurface.new, apis: Host.apis, inventory: Admin::PluginHostSurfaceInventory.new(surface:))
        @directory = Pathname.new(directory).expand_path
        @surface = surface
        @apis = apis
        @inventory = inventory
      end

      def self.cached(directory, **options)
        scanner = new(directory, **options)
        Rails.cache.fetch("plugin-host-surface/v1/#{scanner.content_hash}") { scanner.call }
      end

      def call
        grouped = @inventory.references_for(@directory).map do |reference|
          Finding.new(constant: reference.constant, tier: tier_for(reference.constant), path: reference.path, line: reference.line)
        end.group_by(&:tier)
        public_findings = sorted(grouped.fetch("public", []))
        Result.new(public: public_findings, legacy: sorted(grouped.fetch("legacy", [])),
          unlisted: sorted(grouped.fetch("unlisted", [])), minimum_syrus_version: minimum_version(public_findings),
          content_hash: content_hash, error: nil)
      end

      def content_hash
        @content_hash ||= Digest::SHA256.hexdigest(ruby_files.flat_map { |path| [ path.relative_path_from(@directory).to_s, path.binread ] }.join("\0"))
      end

      private

      def ruby_files
        @ruby_files ||= Admin::PluginHostSurfaceInventory::SOURCE_GLOBS.flat_map do |glob|
          Dir.glob(@directory.join(glob)).sort
        end.uniq.map { |path| Pathname.new(path) }
      end

      def sorted(findings) = findings.sort_by { |item| [ item.path, item.line, item.constant ] }

      def api_for(name)
        @apis.select { |api| name == api.name || name.start_with?("#{api.name}::") }.max_by { |api| api.name.length }
      end

      def tier_for(name)
        return "public" if api_for(name)
        return "legacy" if @surface.lookup(name)

        "unlisted"
      end

      def minimum_version(findings)
        findings.filter_map { |finding| api_for(finding.constant)&.since }
          .map { |version| Gem::Version.new(version) }.max&.to_s
      end
    end
  end
end
