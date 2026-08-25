require "mysql2"

module MysqlDbBrowser
  # Schema introspection for an explicit external MySQL connection (host,
  # port, decrypted credentials) - as opposed to AdminMysql::Inspector, which
  # always introspects Syrus's own ActiveRecord::Base.connection. Mirrors
  # AdminMysql::Inspector's safe-section/timeout-hint/truncation design, but
  # is built around a standalone Mysql2::Client so it can point at any
  # registered MysqlConnection.
  class SchemaInspector
    CONNECT_TIMEOUT_SECONDS = 5
    QUERY_TIMEOUT_MS = 3_000
    MAX_TABLES = 500
    MAX_COLUMNS = 1_000
    MAX_INDEXES = 500

    # Always browsable alongside user databases, per the issue - these are
    # ordinary rows in information_schema.SCHEMATA so no special-casing is
    # needed beyond flagging them for the UI.
    SYSTEM_SCHEMAS = %w[information_schema performance_schema mysql sys].freeze

    class Unavailable < StandardError; end
    class NotFound < StandardError; end

    class_attribute :client_factory, default: ->(options) { Mysql2::Client.new(**options) }

    def initialize(connection)
      @connection = connection
    end

    def databases
      with_client do |client|
        rows = query(client, <<~SQL.squish)
          SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
          FROM information_schema.SCHEMATA
          ORDER BY SCHEMA_NAME
        SQL

        {
          available: true,
          generated_at: Time.current.iso8601,
          databases: rows.map { |row| database_payload(row) }
        }
      end
    end

    def tables(database)
      with_client do |client|
        safe_section do
          rows = query(client, <<~SQL.squish)
            SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH,
                   CREATE_TIME, UPDATE_TIME, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = #{quote(client, database)}
            ORDER BY TABLE_NAME
          SQL

          {
            available: true,
            generated_at: Time.current.iso8601,
            database: database,
            system_schema: system_schema?(database),
            truncated: rows.length > MAX_TABLES,
            tables: rows.first(MAX_TABLES).map { |row| table_summary_payload(row) }
          }
        end
      end
    end

    def table(database, table_name)
      with_client do |client|
        {
          database: database,
          table: table_name,
          system_schema: system_schema?(database),
          generated_at: Time.current.iso8601,
          info: safe_section { table_info(client, database, table_name) },
          columns: safe_section { columns(client, database, table_name) },
          indexes: safe_section { indexes(client, database, table_name) }
        }
      end
    end

    private

    attr_reader :connection

    def with_client
      client = build_client
      yield client
    rescue Mysql2::Error => e
      raise Unavailable, e.message
    ensure
      client&.close
    end

    def build_client
      self.class.client_factory.call(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        password: connection.password,
        database: connection.default_database.presence,
        connect_timeout: CONNECT_TIMEOUT_SECONDS,
        read_timeout: CONNECT_TIMEOUT_SECONDS
      )
    end

    def query(client, sql)
      client.query(mysql_timeout_hint(sql)).to_a
    end

    # Guards against a slow/unreachable external host hanging a request, same
    # posture as AdminMysql::Inspector#mysql_timeout_hint.
    def mysql_timeout_hint(sql)
      sql.to_s.sub(/\ASELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{QUERY_TIMEOUT_MS}) */")
    end

    def quote(client, value)
      "'#{client.escape(value.to_s)}'"
    end

    def system_schema?(database)
      SYSTEM_SCHEMAS.include?(database.to_s)
    end

    def safe_section
      yield
    rescue Mysql2::Error => e
      { available: false, error: error_payload(e) }
    end

    def database_payload(row)
      name = row["SCHEMA_NAME"]
      {
        name: name,
        system_schema: system_schema?(name),
        default_character_set: row["DEFAULT_CHARACTER_SET_NAME"],
        default_collation: row["DEFAULT_COLLATION_NAME"]
      }
    end

    def table_summary_payload(row)
      {
        name: row["TABLE_NAME"],
        type: row["TABLE_TYPE"],
        engine: row["ENGINE"],
        approximate_row_count: integer(row["TABLE_ROWS"]),
        data_length_bytes: integer(row["DATA_LENGTH"]),
        index_length_bytes: integer(row["INDEX_LENGTH"]),
        created_at: row["CREATE_TIME"]&.iso8601,
        updated_at: row["UPDATE_TIME"]&.iso8601,
        comment: row["TABLE_COMMENT"].presence
      }
    end

    def table_info(client, database, table_name)
      rows = query(client, <<~SQL.squish)
        SELECT TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, AUTO_INCREMENT,
               CREATE_TIME, UPDATE_TIME, TABLE_COLLATION, TABLE_COMMENT
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = #{quote(client, database)} AND TABLE_NAME = #{quote(client, table_name)}
      SQL

      row = rows.first
      raise NotFound, "Table #{database}.#{table_name} was not found" unless row

      {
        available: true,
        type: row["TABLE_TYPE"],
        engine: row["ENGINE"],
        approximate_row_count: integer(row["TABLE_ROWS"]),
        data_length_bytes: integer(row["DATA_LENGTH"]),
        index_length_bytes: integer(row["INDEX_LENGTH"]),
        auto_increment: integer(row["AUTO_INCREMENT"]),
        created_at: row["CREATE_TIME"]&.iso8601,
        updated_at: row["UPDATE_TIME"]&.iso8601,
        collation: row["TABLE_COLLATION"],
        comment: row["TABLE_COMMENT"].presence
      }
    end

    def columns(client, database, table_name)
      rows = query(client, <<~SQL.squish)
        SELECT COLUMN_NAME, COLUMN_TYPE, DATA_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT,
               EXTRA, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, COLUMN_COMMENT
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = #{quote(client, database)} AND TABLE_NAME = #{quote(client, table_name)}
        ORDER BY ORDINAL_POSITION
      SQL

      {
        available: true,
        truncated: rows.length > MAX_COLUMNS,
        rows: rows.first(MAX_COLUMNS).map { |row| column_payload(row) }
      }
    end

    def column_payload(row)
      {
        name: row["COLUMN_NAME"],
        column_type: row["COLUMN_TYPE"],
        data_type: row["DATA_TYPE"],
        nullable: row["IS_NULLABLE"] == "YES",
        key: row["COLUMN_KEY"].presence,
        default: row["COLUMN_DEFAULT"],
        extra: row["EXTRA"].presence,
        character_max_length: integer(row["CHARACTER_MAXIMUM_LENGTH"]),
        numeric_precision: integer(row["NUMERIC_PRECISION"]),
        numeric_scale: integer(row["NUMERIC_SCALE"]),
        comment: row["COLUMN_COMMENT"].presence
      }
    end

    def indexes(client, database, table_name)
      rows = query(client, <<~SQL.squish)
        SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, INDEX_TYPE
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = #{quote(client, database)} AND TABLE_NAME = #{quote(client, table_name)}
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
      SQL

      list = rows.group_by { |row| row["INDEX_NAME"] }.map do |name, index_rows|
        {
          name: name,
          unique: integer(index_rows.first["NON_UNIQUE"]).to_i.zero?,
          type: index_rows.first["INDEX_TYPE"],
          columns: index_rows.sort_by { |row| integer(row["SEQ_IN_INDEX"]).to_i }.map { |row| row["COLUMN_NAME"] }
        }
      end

      { available: true, truncated: list.length > MAX_INDEXES, rows: list.first(MAX_INDEXES) }
    end

    def integer(value)
      Integer(value, exception: false) if value
    end

    def error_payload(error)
      message = error.message.to_s
      payload = { class: error.class.name, message: message }

      if message.include?("command denied")
        payload[:hint] = "This MySQL user lacks SELECT privileges on information_schema for this section. " \
          "Grant broader read access to browse it."
      end

      payload
    end
  end
end
