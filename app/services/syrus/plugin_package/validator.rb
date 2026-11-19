require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "tmpdir"
require "zlib"
require "syrus/plugin_host_surface/scanner"

module Syrus
  module PluginPackage
    class Validator
      Error = Class.new(StandardError)
      FORMAT_VERSION = 1
      MAX_FILES = 10_000
      MAX_FILE_SIZE = 50.megabytes
      MAX_TOTAL_SIZE = 250.megabytes

      Result = Data.define(:valid, :errors, :manifest) do
        def valid? = valid
      end

      def initialize(archive, max_files: MAX_FILES, max_file_size: MAX_FILE_SIZE, max_total_size: MAX_TOTAL_SIZE)
        @archive = archive
        @max_files = max_files
        @max_file_size = max_file_size
        @max_total_size = max_total_size
      end

      def call
        entries = read_entries
        manifest = parse_json(entries.fetch("package.json")[:data], "package.json")
        errors = validate_manifest(manifest, entries)
        errors.concat(validate_checksums(entries))
        errors.concat(validate_plugin(entries, manifest))
        Result.new(valid: errors.empty?, errors:, manifest:)
      rescue Error, KeyError, JSON::ParserError, Zlib::GzipFile::Error, Gem::Package::TarInvalidError => error
        Result.new(valid: false, errors: [ error.message ], manifest: nil)
      end

      def validate!
        result = call
        raise Error, result.errors.join("; ") unless result.valid?
        result
      end

      private

      def read_entries
        entries = {}
        total = 0
        io = @archive.respond_to?(:read) ? @archive : File.open(@archive, "rb")
        Zlib::GzipReader.wrap(io) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              path = entry.full_name
              raise Error, "unsafe package path: #{path}" unless safe_path?(path)
              raise Error, "duplicate package path: #{path}" if entries.key?(path)
              raise Error, "package contains too many files" if entries.length >= @max_files
              raise Error, "package contains links: #{path}" if entry.header.typeflag == "1" || entry.header.typeflag == "2"
              next if entry.directory?
              raise Error, "package file is too large: #{path}" if entry.header.size > @max_file_size
              total += entry.header.size
              raise Error, "package is too large" if total > @max_total_size
              entries[path] = { data: entry.read, mode: entry.header.mode }
            end
          end
        end
        entries
      ensure
        io.close if io && !@archive.respond_to?(:read)
      end

      def safe_path?(path)
        normalized = path.delete_suffix("/")
        normalized.present? && !normalized.start_with?("/", "\\") && normalized.split("/").none? { |part| part.empty? || part == "." || part == ".." }
      end

      def parse_json(value, name)
        JSON.parse(value)
      rescue JSON::ParserError => error
        raise Error, "invalid #{name}: #{error.message}"
      end

      def validate_manifest(manifest, entries)
        errors = []
        errors << "unsupported package format version" unless manifest["format_version"] == FORMAT_VERSION
        errors << "invalid plugin name" unless manifest["name"].to_s.match?(/\A[a-z][a-z0-9_]*\z/)
        errors << "missing plugin version" if manifest["version"].blank?
        files = manifest["files"]
        errors << "manifest files must be an array" unless files.is_a?(Array)
        return errors unless files.is_a?(Array)
        declared = files.to_h { |item| [ item["path"], item["sha256"] ] }
        actual = entries.except("package.json", "CHECKSUMS.sha256").transform_values { |entry| Digest::SHA256.hexdigest(entry[:data]) }
        errors << "manifest file list does not match package contents" unless declared == actual
        errors
      end

      def validate_checksums(entries)
        expected = entries.fetch("CHECKSUMS.sha256")[:data].lines.to_h do |line|
          digest, path = line.strip.split(/\s+/, 2)
          [ path, digest ]
        end
        actual = entries.except("CHECKSUMS.sha256").transform_values { |entry| Digest::SHA256.hexdigest(entry[:data]) }
        expected == actual ? [] : [ "checksum file does not match package contents" ]
      end

      def validate_plugin(entries, manifest)
        errors = []
        gemspecs = entries.keys.grep(%r{\Aplugin/[^/]+\.gemspec\z})
        errors << "package must contain exactly one plugin gemspec" unless gemspecs.one?
        if gemspecs.one?
          source = entries.fetch(gemspecs.first)[:data]
          dependencies = source.scan(/add_(?:runtime_)?dependency\s*(?:\(?\s*)?["']([^"']+)/).flatten - [ "rails" ]
          errors << "plugin has unsupported gem dependencies: #{dependencies.sort.join(', ')}" if dependencies.any?
          errors << "manifest name does not match gemspec" unless source.match?(/spec\.name\s*=\s*["']#{Regexp.escape(manifest["name"].to_s)}["']/)
          errors << "manifest version does not match gemspec" unless source.match?(/spec\.version\s*=\s*["']#{Regexp.escape(manifest["version"].to_s)}["']/)
          errors << "manifest requires_syrus does not match gemspec" unless source.include?(manifest["requires_syrus"].to_s)
        end
        ruby = entries.select { |path, _| path.end_with?(".rb") }.values.map { |entry| entry[:data] }.join("\n")
        errors << "plugin uses a non-public Syrus API" if ruby.match?(/\b(?:Job|Workflow|Run|Repository|GithubClient)(?:::)?/) || ruby.include?("Syrus::PluginRegistry")
        declared_extension_points = ruby.scan(/provides\s+([a-z_]+):/).flatten.uniq.sort
        declared_routes = ruby.scan(/route\s+:[a-z]+,\s*["']([^"']+)/).flatten.uniq.sort
        declared_credentials = ruby.scan(/credential_type_names?\s+["']([^"']+)/).flatten.uniq.sort
        declared_commands = ruby.scan(/path:\s*%w\[([^\]]+)\]/).flatten.map { |path| path.split.join(" ") }.uniq.sort
        errors << "manifest extension_points does not match contained code" unless Array(manifest["extension_points"]).sort == declared_extension_points
        errors << "manifest routes does not match contained code" unless Array(manifest["routes"]).sort == declared_routes
        errors << "manifest credential_types does not match contained code" unless Array(manifest["credential_types"]).sort == declared_credentials
        errors << "manifest cli_commands does not match contained code" unless Array(manifest["cli_commands"]).sort == declared_commands
        Dir.mktmpdir("plugin-package-scan") do |directory|
          entries.each do |path, entry|
            next unless path.start_with?("plugin/")
            target = File.join(directory, path.delete_prefix("plugin/"))
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, entry[:data])
          end
          scan = Syrus::PluginHostSurface::Scanner.new(directory).call
          errors << "plugin uses non-public host APIs: #{scan.unlisted.map(&:constant).uniq.sort.join(', ')}" if scan.unlisted.any?
          public_apis = scan.public.map(&:constant).uniq.sort
          errors << "manifest public_host_apis does not match contained code" unless Array(manifest["public_host_apis"]).sort == public_apis
        end
        errors
      end
    end
  end
end
