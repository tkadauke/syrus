require "sqlite3"

module LocalBackups
  class SqliteSnapshot
    Result = Data.define(:path, :sqlite_version, :schema_version, :page_count, :bytes, :integrity)

    def initialize(source: ActiveRecord::Base.connection_db_config.database)
      @source = Pathname.new(source)
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
