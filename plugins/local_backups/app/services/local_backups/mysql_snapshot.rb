require "digest"
require "zlib"

module LocalBackups
  class MysqlSnapshot
    Result = Data.define(:path, :client_version, :server_version, :schema_version, :bytes, :integrity)
    UnsupportedEngine = Class.new(StandardError)
    DumpFailed = Class.new(StandardError)

    def initialize(connection: ActiveRecord::Base.connection, config: ActiveRecord::Base.connection_db_config.configuration_hash,
      runner: ProcessRunner, executable: "mysqldump")
      @connection = connection
      @config = config.symbolize_keys
      @runner = runner
      @executable = executable
    end

    def create(destination)
      reject_unsupported_engines!
      destination = Pathname.new(destination)
      raw = destination.sub_ext("")
      client_version = capture_client_version(destination.dirname)
      result = run_dump(raw)
      raise DumpFailed, "MySQL logical snapshot failed (exit #{result.exit_status})" unless result.success?

      compress(raw, destination)
      FileUtils.rm_f(raw)
      Result.new(path: destination, client_version:, server_version: @connection.select_value("SELECT VERSION()"),
        schema_version: ActiveRecord::Migrator.current_version, bytes: destination.size,
        integrity: "transactionally consistent logical dump")
    ensure
      FileUtils.rm_f(raw) if defined?(raw) && raw
    end

    def adapter = "mysql2"
    def destination_filename = "primary.sql.gz"

    def estimate_bytes
      @connection.select_value("SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.TABLES WHERE table_schema = DATABASE()").to_i
    end

    def select_blobs(_snapshot)
      ActiveStorage::Blob.order(:id).pluck(:id, :key, :byte_size, :content_type, :checksum).map do |values|
        %w[id key byte_size content_type checksum].zip(values).to_h
      end
    end

    def manifest(snapshot)
      { adapter:, path: "database/#{snapshot.path.basename}", server_version: snapshot.server_version,
        client_version: snapshot.client_version, schema_version: snapshot.schema_version, bytes: snapshot.bytes,
        integrity: snapshot.integrity, dump_encoding: "gzip-compressed SQL" }
    end

    private

    def reject_unsupported_engines!
      rows = @connection.select_rows(<<~SQL.squish)
        SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB'
      SQL
      return if rows.empty?

      details = rows.map { |table, engine| "#{table}=#{engine}" }.join(", ")
      raise UnsupportedEngine, "MySQL backup requires InnoDB tables; unsupported engines: #{details}"
    end

    def run_dump(raw)
      @runner.new(env: dump_environment, command: dump_command(raw), display_command: redacted_command(raw),
        mounts: ProcessRunner.mounts(raw.dirname), network: "prepare", timeout: 2.hours,
        kind: "backup_database_snapshot").run
    end

    def capture_client_version(directory)
      capture = @runner.new(env: {}, command: [@executable, "--version"],
        mounts: ProcessRunner.mounts(directory), network: "grader", timeout: 30,
        kind: "backup_database_probe").capture(stdout_limit: 4096, stderr_limit: 4096)
      raise DumpFailed, "mysqldump is unavailable" unless capture.success?

      capture.stdout.strip
    end

    def dump_command(raw)
      [@executable, "--single-transaction", "--quick", "--skip-lock-tables", "--hex-blob",
        "--set-gtid-purged=OFF", "--no-tablespaces", "--default-character-set=utf8mb4",
        "--host", @config.fetch(:host, "127.0.0.1").to_s, "--port", @config.fetch(:port, 3306).to_s,
        "--user", @config.fetch(:username).to_s, "--result-file", raw.to_s, @config.fetch(:database).to_s]
    end

    def redacted_command(raw)
      [@executable, "--single-transaction", "--quick", "--skip-lock-tables", "--hex-blob",
        "--result-file", raw.to_s, "[database]"]
    end

    def dump_environment
      { "MYSQL_PWD" => @config[:password].to_s }
    end

    def compress(source, destination)
      File.open(source, "rb") do |input|
        Zlib::GzipWriter.open(destination, Zlib::BEST_COMPRESSION) do |output|
          IO.copy_stream(input, output)
        end
      end
      File.chmod(0o600, destination)
    end
  end
end
