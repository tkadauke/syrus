require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"
require "rubygems/package"
require "securerandom"
require "tmpdir"
require "zlib"

module LocalBackups
  module Recovery
    DEFAULT_MAX_BYTES = 20 * 1024 * 1024 * 1024
    COPY_CHUNK = 1024 * 1024

    class Error < StandardError; end
    class InvalidArtifact < Error; end
    class LimitExceeded < Error; end

    Result = Struct.new(:artifact, :manifest, :artifact_checksum, :logical_bytes, keyword_init: true)

    class Artifact
      attr_reader :source, :max_bytes

      def initialize(source, max_bytes: DEFAULT_MAX_BYTES)
        @source = Pathname.new(source).expand_path
        @max_bytes = Integer(max_bytes)
      end

      def with_directory
        if source.directory?
          reject_symlinks!(source)
          return yield(source)
        end
        raise InvalidArtifact, "artifact does not exist: #{source}" unless source.file?
        raise LimitExceeded, "artifact exceeds #{max_bytes} bytes" if source.size > max_bytes

        Dir.mktmpdir("syrus-recovery-") do |temporary|
          extract_archive(Pathname.new(temporary))
          entries = Pathname.new(temporary).children
          root = entries.length == 1 && entries.first.directory? ? entries.first : Pathname.new(temporary)
          yield(root)
        end
      end

      def validate
        with_directory do |root|
          manifest = read_json(root.join("manifest.json"))
          version = manifest.fetch("manifest_version", "")
          raise InvalidArtifact, "unsupported manifest version #{version.inspect}" unless version.match?(/\A1(?:\.\d+)?\z/)

          checksum_path = root.join("checksums.sha256")
          raise InvalidArtifact, "checksum inventory is missing" unless checksum_path.file?
          total = 0
          seen = {}
          checksum_path.each_line.with_index(1) do |line, number|
            expected, relative = line.strip.split(/\s+/, 2)
            unless expected&.match?(/\A[0-9a-f]{64}\z/) && relative && !relative.empty?
              raise InvalidArtifact, "malformed checksum inventory at line #{number}"
            end
            raise InvalidArtifact, "duplicate checksum path #{relative}" if seen[relative]
            seen[relative] = true
            path = contained(root, relative)
            raise InvalidArtifact, "checksum target is not a regular file: #{relative}" unless path.file?
            total += path.size
            raise LimitExceeded, "extracted contents exceed #{max_bytes} bytes" if total > max_bytes
            raise InvalidArtifact, "checksum mismatch for #{relative}" unless Digest::SHA256.file(path).hexdigest == expected
          end
          declared = manifest["checksum"]
          declared = declared["value"] if declared.is_a?(Hash)
          actual = Digest::SHA256.file(checksum_path).hexdigest
          raise InvalidArtifact, "artifact checksum does not match manifest" if declared && declared != actual
          Result.new(artifact: source.to_s, manifest:, artifact_checksum: actual, logical_bytes: total)
        end
      rescue JSON::ParserError, KeyError => e
        raise InvalidArtifact, e.message
      end

      private

      def extract_archive(destination)
        io = archive_io
        count = 0
        Gem::Package::TarReader.new(io) do |tar|
          tar.each do |entry|
            relative = safe_relative(entry.full_name)
            target = destination.join(relative)
            if entry.directory?
              target.mkpath
            elsif entry.file?
              count += entry.header.size
              raise LimitExceeded, "expanded archive exceeds #{max_bytes} bytes" if count > max_bytes
              target.dirname.mkpath
              File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
                while (chunk = entry.read(COPY_CHUNK)) && !chunk.empty?
                  output.write(chunk)
                end
              end
            else
              raise InvalidArtifact, "archive contains a link or special entry: #{entry.full_name}"
            end
          end
        end
      rescue Gem::Package::TarInvalidError, Zlib::GzipFile::Error => e
        raise InvalidArtifact, "invalid archive: #{e.message}"
      ensure
        io&.close
      end

      def archive_io
        return Zlib::GzipReader.new(source.open("rb")) if source.to_s.end_with?(".gz", ".tgz")
        return IO.popen(["zstd", "-dc", "--", source.to_s], "rb") if source.to_s.end_with?(".zst")
        source.open("rb")
      rescue Errno::ENOENT
        raise InvalidArtifact, "zstd is required to read this artifact"
      end

      def contained(root, relative)
        clean = safe_relative(relative)
        path = root.join(clean)
        raise InvalidArtifact, "checksum target is missing: #{relative}" unless path.exist?
        resolved = path.realpath
        prefix = "#{root.realpath}#{File::SEPARATOR}"
        raise InvalidArtifact, "path escapes artifact: #{relative}" unless resolved.to_s.start_with?(prefix)
        resolved
      end

      def safe_relative(value)
        path = Pathname.new(value).cleanpath
        first = path.each_filename.first
        raise InvalidArtifact, "path escapes artifact: #{value}" if path.absolute? || first == ".." || value.include?("\\")
        path
      end

      def reject_symlinks!(root)
        root.find { |path| raise InvalidArtifact, "artifact contains a symlink: #{path.relative_path_from(root)}" if path.symlink? }
      end

      def read_json(path)
        raise InvalidArtifact, "manifest is missing" unless path.file?
        JSON.parse(path.binread)
      end
    end

    class Preflight
      def self.token_for(checksum, identity)
        Digest::SHA256.hexdigest("syrus-recovery-preflight-v1\0#{checksum}\0#{identity}")
      end

      def self.verify_token!(provided:, checksum:, identity:)
        expected = token_for(checksum, identity)
        raise Error, "preflight token is stale or belongs to another artifact or installation" unless
          provided.to_s.bytesize == expected.bytesize && secure_compare(provided.to_s, expected)
        true
      end

      def self.secure_compare(left, right)
        left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
      end

      def initialize(artifact:, environment: ENV)
        @artifact = artifact
        @environment = environment
      end

      def call
        result = @artifact.validate
        manifest = result.manifest
        checks = []
        checks << check("manifest_and_checksums", true, "manifest v#{manifest['manifest_version']} and all checksums are valid")
        checks << compatibility_check("application", manifest["source_application_version"], @environment["SYRUS_VERSION"])
        checks << database_check(manifest["database"] || {})
        checks.concat(plugin_checks(manifest["plugins"] || {}))
        checks.concat(key_checks(manifest["encryption_key_fingerprints"] || {}))
        checks << destination_check
        checks << space_check(result.logical_bytes)
        checks << database_health_check
        checks << check("safety_backup", database_available?,
          database_available? ? "can be created before restore" : "unavailable until the source database is healthy",
          status: database_available? ? nil : "warning")
        identity = installation_identity
        checks << installation_check(manifest["installation_id"], identity)
        {
          status: checks.any? { |item| item[:status] == "failed" } ? "failed" : "ready",
          artifact: result.artifact, artifact_checksum: result.artifact_checksum,
          installation_identity: identity, preflight_token: self.class.token_for(result.artifact_checksum, identity),
          checks:, expected_rebuilds: %w[chat_search derived_indexes repository_caches],
          in_flight_work: in_flight_work
        }
      end

      private

      def check(name, passed, message, status: nil)
        { name:, status: status || (passed ? "passed" : "failed"), message: }
      end

      def compatibility_check(name, source, current)
        return check("#{name}_compatibility", true, "current version was not supplied; verify before execution", status: "warning") if current.to_s.empty?
        source_major = source.to_s[/\d+/]
        current_major = current.to_s[/\d+/]
        compatible = source_major && current_major ? source_major == current_major : source.to_s == current.to_s
        check("#{name}_compatibility", compatible, "bundle=#{source || 'unknown'}, current=#{current}")
      end

      def database_check(database)
        expected = @environment["SYRUS_DATABASE_ADAPTER"]
        actual = database["adapter"]
        return check("database_compatibility", true, "bundle adapter=#{actual || 'unknown'}; destination adapter was not supplied", status: "warning") if expected.to_s.empty?
        version = database["server_version"] || database["version"]
        current_version = @environment["SYRUS_DATABASE_VERSION"]
        version_compatible = current_version.to_s.empty? || version.to_s.empty? || version.to_s[/\d+/] == current_version.to_s[/\d+/]
        check("database_compatibility", expected == actual && version_compatible,
          "bundle=#{actual || 'unknown'} #{version || 'unknown'}, destination=#{expected} #{current_version || 'unknown'}")
      end

      def plugin_checks(required)
        installed = @environment.fetch("SYRUS_INSTALLED_PLUGINS", "").split(",").filter_map { |entry| entry.split("=", 2).then { |name, version| [name.strip, version] unless name.strip.empty? } }.to_h
        required.map do |name, version|
          compatible = installed.key?(name) && (version.to_s.empty? || installed[name].to_s == version.to_s)
          check("plugin:#{name}", compatible,
            installed.key?(name) ? "installed=#{installed[name] || 'unknown'}, bundle=#{version}" : "required plugin is absent")
        end
      end

      def key_checks(required)
        required.map do |name, fingerprint|
          current = @environment["SYRUS_RECOVERY_KEY_#{name.upcase.gsub(/[^A-Z0-9]/, '_')}"]
          check("encryption_key:#{name}", current == fingerprint, current ? "fingerprint #{current == fingerprint ? 'matches' : 'does not match'}" : "current fingerprint was not supplied")
        end
      end

      def destination_check
        path = Pathname.new(@environment.fetch("SYRUS_RECOVERY_DESTINATION", Dir.pwd)).expand_path
        storage_healthy = @environment.fetch("SYRUS_ACTIVE_STORAGE_HEALTHY", "1") == "1"
        check("destination_health", path.directory? && path.writable? && storage_healthy,
          "#{path} must exist and be writable; Active Storage health=#{storage_healthy}")
      end

      def installation_check(source_identity, current_identity)
        return check("installation_identity", true, "bundle does not declare its source identity", status: "warning") if source_identity.to_s.empty?
        check("installation_identity", source_identity == current_identity,
          "bundle=#{source_identity}, destination=#{current_identity}")
      end

      def space_check(logical_bytes)
        available = Integer(@environment.fetch("SYRUS_RECOVERY_AVAILABLE_BYTES", disk_available), exception: false)
        required = logical_bytes * 2
        return check("free_space", true, "free-space probe unavailable; require at least #{required} bytes", status: "warning") unless available
        check("free_space", available >= required, "required=#{required}, available=#{available}")
      end

      def disk_available
        output = IO.popen(["df", "-Pk", @environment.fetch("SYRUS_RECOVERY_DESTINATION", Dir.pwd)], &:read)
        output.lines.last.to_s.split[3].to_i * 1024
      rescue StandardError
        nil
      end

      def database_available? = @environment["SYRUS_DATABASE_AVAILABLE"] == "1"

      def database_health_check
        check("destination_database", database_available?, database_available? ? "reported healthy" : "unavailable; empty-instance bootstrap remains possible", status: database_available? ? nil : "warning")
      end

      def installation_identity
        @environment["SYRUS_INSTALLATION_ID"].to_s.tap { |value| raise Error, "SYRUS_INSTALLATION_ID is required for preflight" if value.empty? }
      end

      def in_flight_work
        count = Integer(@environment.fetch("SYRUS_IN_FLIGHT_WORK_COUNT", "0"), exception: false) || 0
        { count:, consequence: count.positive? ? "workspace files are excluded; restored work will require reconciliation or retry" : "none reported" }
      end
    end

    class Importer
      def initialize(destination:, max_bytes: DEFAULT_MAX_BYTES)
        @destination = Pathname.new(destination).expand_path
        @max_bytes = Integer(max_bytes)
      end

      def import(source)
        artifact = Artifact.new(source, max_bytes: @max_bytes)
        result = artifact.validate
        @destination.mkpath
        name = "#{result.artifact_checksum}-#{File.basename(source.to_s)}"
        target = @destination.join(name)
        raise Error, "import target already exists: #{target}" if target.exist?
        copy_bounded(Pathname.new(source), target)
        { imported_to: target.to_s, artifact_checksum: result.artifact_checksum }
      end

      def receive(io)
        @destination.mkpath
        temporary = @destination.join(".upload-#{SecureRandom.hex(8)}.partial")
        write_bounded(io, temporary)
        import(temporary)
      ensure
        temporary&.delete if temporary&.exist?
      end

      private

      def copy_bounded(source, target)
        if source.directory?
          total = source.find.sum { |path| path.file? ? path.size : 0 }
          raise LimitExceeded, "import exceeds #{@max_bytes} bytes" if total > @max_bytes
          source.find { |path| raise InvalidArtifact, "import contains a symlink" if path.symlink? }
          FileUtils.cp_r(source, target, preserve: true)
        else
          source.open("rb") { |input| File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |output| stream(input, output) } }
        end
      rescue StandardError
        FileUtils.rm_rf(target) if target.exist?
        raise
      end

      def write_bounded(io, path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |output| stream(io, output) }
      end

      def stream(input, output)
        total = 0
        while (chunk = input.read(COPY_CHUNK)) && !chunk.empty?
          total += chunk.bytesize
          raise LimitExceeded, "import exceeds #{@max_bytes} bytes" if total > @max_bytes
          output.write(chunk)
        end
      end
    end
  end
end
