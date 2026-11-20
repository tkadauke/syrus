# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "open3"
require "pathname"
require "rubygems/package"
require "securerandom"
require "tmpdir"

module LocalBackups
  module Recovery
    DEFAULT_MAX_BYTES = 50 * 1024 * 1024 * 1024
    DEFAULT_MAX_FILES = 1_000_000

    class Error < StandardError; end

    class Bundle
      attr_reader :path, :manifest, :total_bytes

      def initialize(path, max_bytes: DEFAULT_MAX_BYTES, max_files: DEFAULT_MAX_FILES)
        @path = Pathname.new(path).realpath
        @max_bytes = max_bytes
        @max_files = max_files
        raise Error, "bundle must be a directory" unless @path.directory?
        reject_unsafe_tree!
        @manifest = parse_manifest
      rescue Errno::ENOENT
        raise Error, "bundle does not exist"
      end

      def self.materialize(input, max_bytes: DEFAULT_MAX_BYTES, max_files: DEFAULT_MAX_FILES)
        staging = Pathname.new(Dir.mktmpdir("syrus-recovery-"))
        count = 0
        total = 0
        Gem::Package::TarReader.new(input) do |tar|
          tar.each do |entry|
            count += 1
            raise Error, "archive contains too many entries" if count > max_files
            relative = safe_relative(entry.full_name)
            target = staging.join(relative)
            if entry.directory?
              target.mkpath
            elsif entry.file?
              total += entry.header.size
              raise Error, "archive exceeds the expanded size limit" if total > max_bytes
              target.dirname.mkpath
              File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
                while (chunk = entry.read(64 * 1024)) && !chunk.empty?
                  file.write(chunk)
                end
              end
            else
              raise Error, "archive contains a link or special file"
            end
          end
        end
        new(staging, max_bytes:, max_files:)
      rescue StandardError
        FileUtils.remove_entry_secure(staging) if staging&.exist?
        raise
      end

      def self.safe_relative(name)
        value = Pathname.new(name.to_s)
        clean = value.cleanpath
        if value.absolute? || clean.to_s == "." || clean.each_filename.first == ".."
          raise Error, "archive path escapes the bundle"
        end
        clean
      end

      def validate!
        inventory = contained_file(manifest.dig("artifact", "checksum_path") || "checksums.sha256")
        raise Error, "checksum inventory is missing" unless inventory.file?
        expected_inventory = manifest_checksum
        actual_inventory = Digest::SHA256.file(inventory).hexdigest
        raise Error, "artifact checksum does not match its manifest" unless expected_inventory == actual_inventory

        entries = 0
        inventory.each_line do |line|
          expected, relative = line.strip.split(/\s+/, 2)
          unless expected&.match?(/\A[0-9a-f]{64}\z/) && relative && !relative.empty?
            raise Error, "checksum inventory is malformed"
          end
          target = contained_file(relative)
          raise Error, "checksum target is missing: #{relative}" unless target.file?
          raise Error, "checksum mismatch: #{relative}" unless Digest::SHA256.file(target).hexdigest == expected
          entries += 1
        end
        raise Error, "checksum inventory is empty" if entries.zero?
        self
      end

      def checksum = manifest_checksum

      def identity_checksum
        digest = Digest::SHA256.new
        path.find.select(&:file?).sort_by { |entry| entry.relative_path_from(path).to_s }.each do |entry|
          relative = entry.relative_path_from(path).to_s
          digest << relative << "\0" << Digest::SHA256.file(entry).hexdigest << "\0"
        end
        digest.hexdigest
      end

      private

      def parse_manifest
        file = contained_file("manifest.json")
        payload = JSON.parse(file.binread)
        required = %w[manifest_version backup_id completed_at artifact checksum]
        missing = required - payload.keys
        raise Error, "manifest is missing #{missing.join(', ')}" if missing.any?
        major, minor = payload.fetch("manifest_version").to_s.split(".", 2).map { |part| Integer(part, 10) }
        raise Error, "unsupported manifest version" unless major == 1 && minor >= 0
        payload.freeze
      rescue JSON::ParserError, ArgumentError, TypeError => error
        raise Error, "invalid manifest: #{error.message}"
      end

      def manifest_checksum
        value = manifest.fetch("checksum")
        value = value["value"] if value.is_a?(Hash)
        raise Error, "manifest checksum is not SHA-256" unless value.to_s.match?(/\A[0-9a-f]{64}\z/)
        value
      end

      def contained_file(relative)
        clean = self.class.safe_relative(relative)
        candidate = path.join(clean)
        resolved = candidate.realpath
        unless resolved.to_s.start_with?("#{path}#{File::SEPARATOR}")
          raise Error, "bundle path escapes its root"
        end
        resolved
      rescue Errno::ENOENT
        candidate
      end

      def reject_unsafe_tree!
        count = 0
        @total_bytes = 0
        path.find do |entry|
          next if entry == path
          count += 1
          raise Error, "bundle contains too many entries" if count > @max_files
          raise Error, "bundle contains a symbolic link" if entry.symlink?
          raise Error, "bundle contains a special file" unless entry.file? || entry.directory?
          if entry.file?
            @total_bytes += entry.size
            raise Error, "bundle exceeds the size limit" if @total_bytes > @max_bytes
          end
        end
      end
    end

    class Preflight
      def initialize(bundle:, installation_id:, destination:, token_secret:, current: {})
        @bundle = bundle
        @installation_id = installation_id.to_s
        @destination = Pathname.new(destination)
        @token_secret = token_secret.to_s
        @current = current
      end

      def call
        @bundle.validate!
        checks = [destination_check, database_check, version_check, plugins_check, encryption_check, in_flight_check]
        failures = checks.select { |check| check[:status] == "fail" }
        payload = { artifact_checksum: @bundle.identity_checksum, installation_id: @installation_id }
        {
          status: failures.empty? ? "ready" : "blocked",
          artifact_checksum: @bundle.identity_checksum,
          installation_id: @installation_id,
          required_bytes: required_bytes,
          expected_rebuilds: %w[chat_search repository_indexes clone_caches workflow_workspaces],
          checks:,
          token: failures.empty? ? token(payload) : nil
        }
      end

      private

      def required_bytes = [@bundle.total_bytes * 2, 1].max

      def destination_check
        return result("destination", "fail", "destination is not a writable directory") unless @destination.directory? && @destination.writable?
        output, status = Open3.capture2e("df", "-Pk", @destination.to_s)
        raise Error, "destination capacity is unavailable" unless status.success?
        fields = output.lines.last.to_s.split
        available = Integer(fields.fetch(3), 10) * 1024
        result("destination", available >= required_bytes ? "pass" : "fail", "#{available} bytes available; #{required_bytes} required")
      rescue Errno::ENOENT, Errno::EACCES, ArgumentError, IndexError, Error
        result("destination", "fail", "destination is unavailable")
      end

      def database_check
        expected = @bundle.manifest.dig("database", "adapter")
        actual = @current[:database_adapter]
        return result("database", "warn", "current database adapter was not supplied") if actual.to_s.empty?
        return result("database", "fail", "bundle=#{expected}; destination=#{actual}") unless expected.to_s == actual.to_s

        source_version = @bundle.manifest.dig("database", "server_version") || @bundle.manifest.dig("database", "sqlite_version")
        destination_version = @current[:database_version]
        if source_version && destination_version.to_s.empty?
          return result("database", "warn", "adapters match; destination database version was not supplied")
        end
        if source_version && source_version.to_s.split(".").first != destination_version.to_s.split(".").first
          return result("database", "fail", "database major versions differ: bundle=#{source_version}; destination=#{destination_version}")
        end
        result("database", "pass", "bundle=#{expected}; destination=#{actual}")
      end

      def version_check
        supported = @bundle.manifest.dig("restore_compatibility", "application_versions")
        actual = @current[:application_version]
        return result("application", "warn", "current application version was not supplied") if actual.to_s.empty?
        if supported
          return result("application", Array(supported).include?(actual) ? "pass" : "fail", "destination version #{actual}")
        end

        source = @bundle.manifest["source_application_version"]
        return result("application", "warn", "bundle does not declare an application compatibility range") if source.to_s.empty?
        source_version = Gem::Version.new(source.to_s.delete_prefix("v"))
        destination_version = Gem::Version.new(actual.to_s.delete_prefix("v"))
        result("application", destination_version >= source_version ? "pass" : "fail", "bundle=#{source_version}; destination=#{destination_version}")
      rescue ArgumentError
        result("application", "warn", "application versions are not comparable; no compatibility range was declared")
      end

      def plugins_check
        required = Array(@bundle.manifest["plugins"]).reject { |plugin| plugin["required"] == false }
        available = Array(@current[:plugins]).to_h do |plugin|
          name, version = plugin.to_s.split("=", 2)
          [name, version]
        end
        missing = required.filter_map { |plugin| plugin["name"] unless available.key?(plugin["name"]) }
        incompatible = required.filter_map do |plugin|
          next unless plugin["version"] && available[plugin["name"]] && available[plugin["name"]] != plugin["version"].to_s
          "#{plugin['name']} (bundle #{plugin['version']}, destination #{available[plugin['name']]})"
        end
        failures = missing + incompatible
        result("plugins", failures.empty? ? "pass" : "fail", failures.empty? ? "required plugins are available" : "missing or incompatible: #{failures.join(', ')}")
      end

      def encryption_check
        expected = @bundle.manifest.dig("encryption", "key_fingerprints") || @bundle.manifest.dig("encryption", "key_fingerprint")
        return result("encryption", "warn", "bundle has no encryption-key fingerprints") if expected.nil?
        actual = @current[:encryption_fingerprints]
        return result("encryption", "fail", "current encryption-key fingerprints were not supplied") if actual.nil?
        result("encryption", expected == actual ? "pass" : "fail", expected == actual ? "fingerprints match" : "fingerprints do not match")
      end

      def in_flight_check
        count = @current[:in_flight]
        return result("in_flight_work", "warn", "database unavailable; in-flight work could not be counted") if count.nil?
        result("in_flight_work", count.to_i.zero? ? "pass" : "warn", "#{count.to_i} active workflows will require reconciliation or retry")
      end

      def result(name, status, detail) = { name:, status:, detail: }

      def token(payload)
        raise Error, "installation identity is required for a preflight token" if @installation_id.empty?
        raise Error, "SYRUS_RECOVERY_TOKEN_SECRET is required for a preflight token" if @token_secret.empty?
        Token.issue(secret: @token_secret, **payload.transform_keys(&:to_sym))
      end
    end

    class Token
      def self.issue(secret:, artifact_checksum:, installation_id:)
        raise Error, "installation identity is required for a preflight token" if installation_id.to_s.empty?
        raise Error, "SYRUS_RECOVERY_TOKEN_SECRET is required for a preflight token" if secret.to_s.empty?
        body = JSON.generate({ artifact_checksum:, installation_id: }.sort.to_h)
        "v1.#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
      end

      def self.valid?(token, **attributes)
        expected = issue(**attributes)
        token.to_s.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(token.to_s, expected)
      end
    end

    class Importer
      def initialize(root:, max_bytes: DEFAULT_MAX_BYTES, max_files: DEFAULT_MAX_FILES)
        @root = Pathname.new(root).realpath
        @max_bytes = max_bytes
        @max_files = max_files
      rescue Errno::ENOENT
        raise Error, "import root does not exist"
      end

      def import(bundle)
        bundle.validate!
        backup_id = bundle.manifest.fetch("backup_id").to_s
        unless backup_id.match?(/\A[[:alnum:]][[:alnum:]_.-]*\z/)
          raise Error, "backup_id is not a safe filename"
        end
        destination = @root.join("syrus-backup-import-#{backup_id}")
        raise Error, "bundle is already imported" if destination.exist?
        staging = @root.join(".import-#{SecureRandom.uuid}.partial")
        FileUtils.copy_entry(bundle.path, staging, false, false, true)
        File.rename(staging, destination)
        destination
      ensure
        FileUtils.remove_entry_secure(staging) if staging&.exist?
      end
    end
  end
end
