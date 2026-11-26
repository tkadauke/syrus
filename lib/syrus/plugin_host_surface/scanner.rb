require "digest"
require "syrus/host"
require "syrus/plugin_host_surface"

module Syrus
  class PluginHostSurface
    class Scanner
      Finding = Data.define(:constant, :tier, :path, :line)
      StringFinding = Data.define(:constant, :tier, :path, :line, :method)
      Result = Data.define(:public, :unlisted, :dynamic, :minimum_syrus_version, :content_hash, :error) do
        def violations? = unlisted.any?
        def warnings? = dynamic.any?
        def findings = [ *public, *unlisted, *dynamic ]
      end

      def initialize(directory, surface: PluginHostSurface.new, inventory: Admin::PluginHostSurfaceInventory.new(surface:))
        @directory = Pathname.new(directory).expand_path
        @surface = surface
        @inventory = inventory
      end

      def self.cached(directory, **options)
        scanner = new(directory, **options)
        Rails.cache.fetch("plugin-host-surface/v1/#{scanner.content_hash}") { scanner.call }
      end

      def call
        grouped = @inventory.references_for(@directory).filter_map do |reference|
          tier = tier_for(reference.constant)
          next if tier == "namespace"

          [ tier, Finding.new(constant: reference.constant, tier:, path: reference.path, line: reference.line) ]
        end.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        public_findings = sorted(grouped.fetch("public", []))
        Result.new(public: public_findings,
          unlisted: sorted(grouped.fetch("unlisted", [])), dynamic: dynamic_findings,
          minimum_syrus_version: minimum_version(public_findings),
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

      def tier_for(constant)
        return "namespace" if constant == "Syrus::Host"
        return "public" if @surface.public?(constant)
        return "public" if @surface.allowed_internal?(constant)

        "unlisted"
      end

      def dynamic_findings
        sorted(@inventory.string_references_for(@directory).filter_map do |reference|
          next if reference.constant == "Syrus::Host" || public_api_for(reference.constant)

          StringFinding.new(constant: reference.constant, tier: "dynamic", path: reference.path,
            line: reference.line, method: reference.method)
        end)
      end

      def minimum_version(findings)
        findings.filter_map { |finding| public_api_for(finding.constant)&.since }
          .map { |version| Gem::Version.new(version) }.max&.to_s
      end

      def public_api_for(constant)
        Syrus::Host.apis.select { |api| public_names(api).any? { |name| constant == name || constant.start_with?("#{name}::") } }
          .max_by { |api| api.name.length }
      end

      def public_names(api)
        target_name = api.name.safe_constantize.then { |target| target.respond_to?(:name) && target.is_a?(Module) ? target.name : nil }
        [ api.name, target_name ].compact.uniq
      end
    end
  end
end
