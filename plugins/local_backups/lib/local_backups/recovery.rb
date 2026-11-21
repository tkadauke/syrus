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
require "time"

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

    # Restore intentionally lives in this standard-library-only file. A broken
    # application boot must not take away the recovery path.
    class Command
      def initialize(environment: ENV, output: $stdout)
        @environment = environment
        @output = output
      end

      def run!(name, command, extra_environment = {})
        raise Error, "#{name} command is required" if command.to_s.empty?

        @output.puts("recovery: #{name}")
        success = system(@environment.to_h.merge(extra_environment), command.to_s)
        raise Error, "#{name} failed" unless success
      end
    end

    class Maintenance
      attr_reader :marker

      def initialize(marker:, command:, enter_command:, drain_command:, verify_command:)
        @marker = Pathname.new(marker)
        @command = command
        @enter_command = enter_command
        @drain_command = drain_command
        @verify_command = verify_command
      end

      def enter!
        marker.dirname.mkpath
        File.open(marker, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(pid: Process.pid, entered_at: Time.now.utc.iso8601))
          file.flush
          file.fsync
        end
        @command.run!("maintenance entry", @enter_command)
        @command.run!("worker drain", @drain_command)
        @command.run!("mutating-process verification", @verify_command)
      end

      def leave!(resume_command)
        @command.run!("service resume", resume_command)
        FileUtils.rm_f(marker)
      end
    end

    class SafetyBackup
      attr_reader :path

      def initialize(root:, command:, create_command:, break_glass:, clock: -> { Time.now.utc })
        @root = Pathname.new(root)
        @command = command
        @create_command = create_command
        @break_glass = break_glass
        @clock = clock
      end

      def create!
        if @create_command.to_s.empty?
          raise Error, "pre-restore safety backup is unavailable; pass --break-glass-no-safety-backup to accept destructive recovery without one" unless @break_glass
          return nil
        end

        @path = @root.join("pre-restore-#{@clock.call.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.uuid}")
        @path.mkdir(0o700)
        @command.run!("pre-restore safety backup", @create_command, "SYRUS_PRE_RESTORE_BACKUP_PATH" => @path.to_s)
        bundle = Bundle.new(@path).validate!
        @path.join("PINNED").write("Pinned automatically by disaster recovery.\n", mode: "w", perm: 0o400)
        bundle
      rescue StandardError
        FileUtils.remove_entry_secure(@path) if @path&.exist?
        raise
      end
    end

    class DatabaseRestore
      def self.for(manifest, **options)
        adapter = manifest.dig("database", "adapter").to_s
        driver = { "sqlite3" => SqliteDatabaseRestore, "mysql2" => MysqlDatabaseRestore }.fetch(adapter) do
          raise Error, "restore does not support database adapter #{adapter.inspect}"
        end
        driver.new(manifest:, **options)
      end
    end

    class SqliteDatabaseRestore
      attr_reader :staged_path

      def initialize(manifest:, bundle:, destination:, staging_root:, **)
        @source = bundle.path.join(Bundle.safe_relative(manifest.dig("database", "path")))
        @destination = Pathname.new(destination)
        @staged_path = staging_root.join("database", @destination.basename)
      end

      def stage!
        require "sqlite3"
        staged_path.dirname.mkpath
        FileUtils.copy_file(@source, staged_path)
        File.chmod(0o600, staged_path)
        database = SQLite3::Database.new(staged_path.to_s, readonly: true)
        raise Error, "staged SQLite database failed integrity validation" unless database.get_first_value("PRAGMA integrity_check") == "ok"
      ensure
        database&.close
      end

      def promote!(journal)
        journal.replace(@destination, staged_path)
      end
    end

    class MysqlDatabaseRestore
      def initialize(manifest:, bundle:, command:, staging_root:, mysql_stage_command:, mysql_promote_command:, mysql_rollback_command:, **)
        @source = bundle.path.join(Bundle.safe_relative(manifest.dig("database", "path")))
        @command = command
        @staging_root = staging_root
        @stage_command = mysql_stage_command
        @promote_command = mysql_promote_command
        @rollback_command = mysql_rollback_command
      end

      def stage!
        @command.run!("staged MySQL restore", @stage_command, "SYRUS_RESTORE_DATABASE_DUMP" => @source.to_s,
          "SYRUS_RESTORE_STAGING_ROOT" => @staging_root.to_s)
      end

      def promote!(journal)
        @command.run!("MySQL promotion", @promote_command)
        journal.external_rollback(@rollback_command)
      end
    end

    class ObjectRestore
      def self.for(manifest, **options)
        service = manifest.dig("active_storage", "service").to_s
        driver = { "" => DiskObjectRestore, "Disk" => DiskObjectRestore }.fetch(service, ExternalObjectRestore)
        driver.new(manifest:, **options)
      end
    end

    class DiskObjectRestore
      def initialize(manifest:, bundle:, destination:, staging_root:, **)
        @manifest = manifest
        @bundle = bundle
        @destination = Pathname.new(destination)
        @staged = staging_root.join("objects")
      end

      def stage!
        @staged.mkpath
        Array(@manifest.dig("active_storage", "blobs")).each do |blob|
          relative = Bundle.safe_relative(blob.fetch("relative_path"))
          source = @bundle.path.join(relative)
          target = @staged.join(relative.relative_path_from(Pathname.new("blobs")))
          target.dirname.mkpath
          FileUtils.copy_file(source, target)
          raise Error, "staged object checksum mismatch: #{blob.fetch('id')}" unless Digest::SHA256.file(target).hexdigest == blob.fetch("bundle_checksum")
        end
        actual = @staged.find.count(&:file?)
        expected = Integer(@manifest.dig("active_storage", "blob_count") || 0)
        raise Error, "staged object count mismatch: expected #{expected}, got #{actual}" unless actual == expected
      end

      def promote!(journal)
        journal.replace(@destination, @staged)
      end
    end

    class ExternalObjectRestore
      def initialize(bundle:, command:, staging_root:, object_stage_command:, object_promote_command:, object_rollback_command:, **)
        @bundle = bundle
        @command = command
        @staging_root = staging_root
        @stage_command = object_stage_command
        @promote_command = object_promote_command
        @rollback_command = object_rollback_command
      end

      def stage!
        @command.run!("staged object restore", @stage_command, "SYRUS_RESTORE_BUNDLE" => @bundle.path.to_s,
          "SYRUS_RESTORE_STAGING_ROOT" => @staging_root.to_s)
      end

      def promote!(journal)
        @command.run!("object-store promotion", @promote_command)
        journal.external_rollback(@rollback_command)
      end
    end

    class PromotionJournal
      attr_reader :rollback_steps

      def initialize(root:)
        @root = Pathname.new(root)
        @rollback_steps = []
      end

      def replace(destination, staged)
        destination.dirname.mkpath
        rollback = @root.join("rollback-#{rollback_steps.length}-#{destination.basename}")
        File.rename(destination, rollback) if destination.exist?
        File.rename(staged, destination)
        rollback_steps.unshift(destination: destination.to_s, rollback: rollback.exist? ? rollback.to_s : nil)
      rescue StandardError
        File.rename(rollback, destination) if rollback&.exist? && !destination.exist?
        raise
      end

      def external_rollback(command)
        rollback_steps.unshift(command:) unless command.to_s.empty?
      end

      def instructions
        rollback_steps.map do |step|
          next "run: #{step.fetch(:command)}" if step[:command]
          if step[:rollback]
            "replace #{step.fetch(:destination)} with #{step.fetch(:rollback)}"
          else
            "remove newly-created #{step.fetch(:destination)}"
          end
        end
      end
    end

    class Restore
      Result = Data.define(:status, :artifact_checksum, :safety_backup, :maintenance_marker)

      def initialize(bundle:, token:, token_secret:, installation_id:, destination:, database_destination:, objects_destination:,
        safety_root:, maintenance_marker:, commands:, break_glass: false, output: $stdout, phase_hook: ->(_phase) { })
        @bundle = bundle
        @token = token
        @token_secret = token_secret
        @installation_id = installation_id
        @destination = Pathname.new(destination)
        @database_destination = database_destination
        @objects_destination = objects_destination
        @safety_root = safety_root
        @maintenance_marker = maintenance_marker
        @commands = commands
        @break_glass = break_glass
        @output = output
        @phase_hook = phase_hook
      end

      def call
        @bundle.validate!
        verify_token!
        command = Command.new(output: @output)
        maintenance = Maintenance.new(marker: @maintenance_marker, command:, enter_command: @commands[:enter],
          drain_command: @commands[:drain], verify_command: @commands[:verify_drained])
        maintenance.enter!
        @phase_hook.call(:maintenance_entered)
        safety = SafetyBackup.new(root: @safety_root, command:, create_command: @commands[:safety_backup], break_glass: @break_glass).create!
        @phase_hook.call(:safety_backup_created)

        staging = @destination.join(".restore-#{SecureRandom.uuid}.staged")
        staging.mkdir(0o700)
        journal = PromotionJournal.new(root: staging)
        database = DatabaseRestore.for(@bundle.manifest, bundle: @bundle, destination: @database_destination,
          staging_root: staging, command:, **@commands)
        objects = ObjectRestore.for(@bundle.manifest, bundle: @bundle, destination: @objects_destination,
          staging_root: staging, command:, **@commands)
        database.stage!
        objects.stage!
        @phase_hook.call(:staged)
        database.promote!(journal)
        @phase_hook.call(:database_promoted)
        objects.promote!(journal)
        @phase_hook.call(:objects_promoted)
        run_post_promotion!(command)
        maintenance.leave!(@commands[:resume])
        FileUtils.remove_entry_secure(staging) if staging.exist?
        Result.new(status: "restored", artifact_checksum: @bundle.identity_checksum,
          safety_backup: safety&.path&.to_s, maintenance_marker: maintenance.marker.to_s)
      rescue StandardError => error
        instructions = journal&.instructions || []
        @output.puts(JSON.generate(status: "failed", error: error.message, maintenance_mode: true,
          rollback: instructions, safety_backup: safety&.path&.to_s))
        raise
      end

      private

      def verify_token!
        valid = Token.valid?(@token, secret: @token_secret, artifact_checksum: @bundle.identity_checksum,
          installation_id: @installation_id)
        raise Error, "preflight token is stale or belongs to another artifact or installation" unless valid
      end

      def run_post_promotion!(command)
        command.run!("compatibility-approved migrations", @commands[:migrate]) unless @commands[:migrate].to_s.empty?
        command.run!("derived-index rebuild", @commands[:rebuild])
        command.run!("restored-work reconciliation", @commands[:reconcile])
        command.run!("restored-state health check", @commands[:health_check])
      end
    end
  end
end
