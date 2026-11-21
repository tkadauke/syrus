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
          next unless plugin["version"] && available.key?(plugin["name"]) && available[plugin["name"]] != plugin["version"].to_s
          destination_version = available[plugin["name"]] || "unknown"
          "#{plugin['name']} (bundle #{plugin['version']}, destination #{destination_version})"
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

    # The offline restore intentionally supports only the topology which can be
    # qualified on an ordinary Linux host: SQLite and Disk Active Storage. The
    # deployment-specific MySQL/S3 paths remain fail-closed until their own
    # environment-backed recovery drills exist.
    class Restore
      Result = Data.define(:backup_id, :rollback_path, :database_path, :storage_path)

      def initialize(bundle:, destination:, database_path:, storage_path:, installation_id:, token_secret:, token:,
        pid_files:, break_glass: false, health_check: nil, phase_hook: ->(_phase) { })
        @bundle = bundle
        @destination = Pathname.new(destination)
        @database_path = Pathname.new(database_path)
        @storage_path = Pathname.new(storage_path)
        @installation_id = installation_id.to_s
        @token_secret = token_secret.to_s
        @token = token.to_s
        @pid_files = Array(pid_files).map { |path| Pathname.new(path) }
        @break_glass = break_glass
        @health_check = health_check || RestoredStateCheck.new(@bundle)
        @phase_hook = phase_hook
      end

      def call
        validate_request!
        maintenance = Maintenance.new(@destination)
        maintenance.enter!
        maintenance_entered = true
        maintenance.verify_drained!(@pid_files)
        @phase_hook.call(:maintenance_verified)

        rollback = SafetyCopy.new(@destination, @database_path, @storage_path).create!(break_glass: @break_glass)
        @phase_hook.call(:safety_copy_created)
        staging = stage!
        @phase_hook.call(:staged)
        verify_staging!(staging)
        @phase_hook.call(:staging_verified)
        promote!(staging, rollback)
        @phase_hook.call(:promoted)
        raise Error, "restored-state health check failed" unless @health_check.call(@database_path, @storage_path)

        maintenance.leave!
        @phase_hook.call(:healthy)
        Result.new(backup_id: @bundle.manifest.fetch("backup_id"), rollback_path: rollback&.to_s,
          database_path: @database_path.to_s, storage_path: @storage_path.to_s)
      rescue StandardError => error
        write_failure(error) if maintenance_entered
        raise
      ensure
        FileUtils.remove_entry_secure(staging) if staging&.exist?
      end

      private

      def validate_request!
        @bundle.validate!
        adapter = @bundle.manifest.dig("database", "adapter")
        service = @bundle.manifest.dig("active_storage", "service")
        raise Error, "restore is not qualified for database adapter #{adapter.inspect}" unless adapter == "sqlite3"
        raise Error, "restore is not qualified for Active Storage service #{service.inspect}" unless service == "Disk"
        raise Error, "SYRUS_RECOVERY_TOKEN_SECRET is required for restore" if @token_secret.empty?
        unless Token.valid?(@token, secret: @token_secret, artifact_checksum: @bundle.identity_checksum,
          installation_id: @installation_id)
          raise Error, "preflight token is stale or belongs to another artifact or installation"
        end
        raise Error, "restore destination must be a writable directory" unless @destination.directory? && @destination.writable?
        raise Error, "at least one mutating-process PID file is required" if @pid_files.empty?
      end

      def stage!
        staging = @destination.join(".restore-#{SecureRandom.uuid}.partial")
        staging.mkdir(0o700)
        database_source = @bundle.path.join(safe_manifest_path("database", "path"))
        database_target = staging.join("database.sqlite3")
        FileUtils.copy_file(database_source, database_target)
        File.chmod(0o600, database_target)
        objects_target = staging.join("storage").tap(&:mkpath)
        Array(@bundle.manifest.dig("active_storage", "blobs")).each do |blob|
          relative = Bundle.safe_relative(blob.fetch("relative_path"))
          target = objects_target.join(storage_relative(blob.fetch("key")))
          target.dirname.mkpath
          FileUtils.copy_file(@bundle.path.join(relative), target)
          File.chmod(0o600, target)
        end
        staging
      end

      def verify_staging!(staging)
        database = staging.join("database.sqlite3")
        raise Error, "staged SQLite database is invalid" unless database.binread(16) == "SQLite format 3\0"
        blobs = Array(@bundle.manifest.dig("active_storage", "blobs"))
        raise Error, "staged object count does not match the manifest" unless staging.join("storage").find.count(&:file?) == blobs.length
        blobs.each do |blob|
          target = staging.join("storage", storage_relative(blob.fetch("key")))
          raise Error, "staged object size mismatch" unless target.size == Integer(blob.fetch("byte_size"))
          raise Error, "staged object checksum mismatch" unless Digest::SHA256.file(target).hexdigest == blob.fetch("bundle_checksum")
        end
      rescue Errno::ENOENT, KeyError, ArgumentError
        raise Error, "staged restore contents do not match the manifest"
      end

      def promote!(staging, rollback)
        promoted_database = staging.join("database.sqlite3")
        promoted_storage = staging.join("storage")
        FileUtils.mkdir_p(@database_path.dirname)
        FileUtils.mkdir_p(@storage_path.dirname)
        FileUtils.rm_f(@database_path)
        FileUtils.remove_entry_secure(@storage_path) if @storage_path.exist?
        File.rename(promoted_database, @database_path)
        File.rename(promoted_storage, @storage_path)
      rescue StandardError
        SafetyCopy.restore!(rollback, @database_path, @storage_path) if rollback
        raise
      end

      def safe_manifest_path(*keys)
        Bundle.safe_relative(@bundle.manifest.dig(*keys) || raise(Error, "manifest is missing #{keys.join('.') }"))
      end

      def storage_relative(key)
        clean = Bundle.safe_relative(key)
        value = clean.to_s
        raise Error, "Active Storage key is too short" if value.length < 4
        Pathname.new(value[0, 2]).join(value[2, 2], clean)
      end

      def write_failure(error)
        return unless @destination.directory?
        path = @destination.join("RESTORE_FAILED.json")
        path.write(JSON.pretty_generate(
          status: "maintenance_required", error: error.message,
          rollback: "restore the pinned pre-restore directory, then repeat health checks before removing MAINTENANCE"
        ) + "\n")
        File.chmod(0o600, path)
      rescue StandardError
        nil
      end
    end

    class RestoredStateCheck
      def initialize(bundle)
        @manifest = bundle.manifest
      end

      def call(database_path, _storage_path)
        require "sqlite3"
        database = SQLite3::Database.new(database_path.to_s, readonly: true)
        return false unless database.get_first_value("PRAGMA integrity_check") == "ok"
        expected_schema = @manifest.dig("database", "schema_version")
        return false if expected_schema && database.get_first_value("PRAGMA user_version").to_i != expected_schema.to_i
        expected_blobs = Integer(@manifest.dig("active_storage", "blob_count") || 0)
        database.get_first_value("SELECT COUNT(*) FROM active_storage_blobs").to_i == expected_blobs
      rescue LoadError, SQLite3::Exception, ArgumentError
        false
      ensure
        database&.close
      end
    end

    class Maintenance
      def initialize(root)
        @marker = root.join("MAINTENANCE")
      end

      def enter!
        @marker.write("restore in progress\n")
        File.chmod(0o600, @marker)
      end

      def leave!
        @marker.delete if @marker.exist?
        failure = @marker.dirname.join("RESTORE_FAILED.json")
        failure.delete if failure.exist?
      end

      def verify_drained!(pid_files)
        pid_files.each do |path|
          next unless path.file?
          pid = Integer(path.read.strip, 10)
          Process.kill(0, pid)
          raise Error, "mutating process #{pid} from #{path} is still running"
        rescue Errno::ESRCH
          next
        rescue Errno::EPERM
          raise Error, "cannot verify mutating process #{pid} from #{path}"
        rescue ArgumentError
          raise Error, "invalid PID file: #{path}"
        end
      end
    end

    class SafetyCopy
      def initialize(root, database_path, storage_path)
        @root = root
        @database_path = database_path
        @storage_path = storage_path
      end

      def create!(break_glass:)
        return nil if !@database_path.exist? && !@storage_path.exist?
        destination = @root.join("pre-restore-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}.pinned")
        destination.mkdir(0o700)
        FileUtils.copy_file(@database_path, destination.join("database.sqlite3")) if @database_path.file?
        FileUtils.copy_entry(@storage_path, destination.join("storage"), false, false, true) if @storage_path.directory?
        validate_copy!(destination)
        pin = destination.join("PINNED")
        pin.write("pre-restore safety copy\n")
        File.chmod(0o600, pin)
        destination
      rescue StandardError => error
        FileUtils.remove_entry_secure(destination) if destination&.exist?
        raise Error, "pre-restore safety copy failed: #{error.message}; repeat with --break-glass only after accepting rollback loss" unless break_glass
        nil
      end

      def self.restore!(source, database_path, storage_path)
        return unless source
        FileUtils.rm_f(database_path)
        FileUtils.remove_entry_secure(storage_path) if storage_path.exist?
        FileUtils.copy_file(source.join("database.sqlite3"), database_path) if source.join("database.sqlite3").file?
        FileUtils.copy_entry(source.join("storage"), storage_path, false, false, true) if source.join("storage").directory?
      end

      private

      def validate_copy!(destination)
        if @database_path.file? && Digest::SHA256.file(@database_path).hexdigest != Digest::SHA256.file(destination.join("database.sqlite3")).hexdigest
          raise Error, "pre-restore database copy failed validation"
        end
        return unless @storage_path.directory?
        source = tree_checksums(@storage_path)
        copied = tree_checksums(destination.join("storage"))
        raise Error, "pre-restore object copy failed validation" unless source == copied
      end

      def tree_checksums(root)
        root.find.select(&:file?).to_h do |path|
          [path.relative_path_from(root).to_s, Digest::SHA256.file(path).hexdigest]
        end
      end
    end
  end
end
