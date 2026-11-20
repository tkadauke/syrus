require "sqlite3"

module LocalBackups
  class SqliteSnapshot
    Result = Data.define(:path, :sqlite_version, :schema_version, :page_count, :bytes, :integrity)

    def initialize(source: ActiveRecord::Base.connection_db_config.database, connection: ActiveRecord::Base.connection)
      @source = Pathname.new(source)
      @connection = connection
    end

    def adapter = "sqlite3"
    def destination_filename = "primary.sqlite3"
    def estimate_bytes = @connection.select_value("PRAGMA page_count").to_i * @connection.select_value("PRAGMA page_size").to_i

    def select_blobs(snapshot)
      database = SQLite3::Database.new(snapshot.path.to_s, readonly: true)
      database.results_as_hash = true
      database.execute("SELECT id, key, byte_size, content_type, checksum FROM active_storage_blobs ORDER BY id")
        .map { |row| row.slice("id", "key", "byte_size", "content_type", "checksum") }
    ensure
      database&.close
    end

    def manifest(snapshot)
      { adapter:, path: "database/#{destination_filename}", sqlite_version: snapshot.sqlite_version,
        schema_version: snapshot.schema_version, page_count: snapshot.page_count, bytes: snapshot.bytes,
        integrity: snapshot.integrity }
    end

    def create(destination)
      destination = Pathname.new(destination)
      database = SQLite3::Database.new(@source.to_s)
      database.busy_timeout = 30_000
      database.execute("VACUUM INTO ?", destination.to_s)
      File.chmod(0o600, destination)
      snapshot = SQLite3::Database.new(destination.to_s, readonly: true)
      integrity = snapshot.get_first_value("PRAGMA integrity_check")
      raise Manifest::Invalid, "SQLite snapshot failed integrity validation" unless integrity == "ok"

      Result.new(
        path: destination,
        sqlite_version: snapshot.get_first_value("SELECT sqlite_version()"),
        schema_version: snapshot.get_first_value("PRAGMA user_version"),
        page_count: snapshot.get_first_value("PRAGMA page_count"),
        bytes: destination.size,
        integrity:
      )
    ensure
      snapshot&.close
      database&.close
    end
  end
end
