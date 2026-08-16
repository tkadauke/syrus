module SyrusDev
  class SqlExplain
    MAX_SQL_BYTES = 20_000
    DEFAULT_ANALYZE_TIMEOUT_MS = 1_000
    MAX_ANALYZE_TIMEOUT_MS = 5_000

    Error = Class.new(StandardError)

    Result = Data.define(
      :adapter,
      :mode,
      :normalized_sql,
      :placeholder_substituted,
      :timeout_ms,
      :rows,
      :json_plan,
      :warnings
    ) do
      def as_json(*)
        {
          adapter: adapter,
          mode: mode,
          normalized_sql: normalized_sql,
          placeholder_substituted: placeholder_substituted,
          timeout_ms: timeout_ms,
          rows: rows,
          json_plan: json_plan,
          warnings: warnings
        }
      end
    end

    class << self
      def call(sql:, analyze: false, timeout_ms: DEFAULT_ANALYZE_TIMEOUT_MS)
        new(sql: sql, analyze: analyze, timeout_ms: timeout_ms).call
      end
    end

    def initialize(sql:, analyze:, timeout_ms:)
      @sql = sql.to_s
      @analyze = ActiveModel::Type::Boolean.new.cast(analyze)
      @timeout_ms = normalized_timeout(timeout_ms)
    end

    def call
      validate!
      connection = ActiveRecord::Base.connection
      adapter = connection.adapter_name.to_s.downcase

      if adapter.include?("mysql")
        mysql_explain(connection, adapter)
      elsif analyze?
        raise Error, "EXPLAIN ANALYZE is only enabled for MySQL connections"
      else
        sqlite_explain(connection, adapter)
      end
    end

    private

    attr_reader :sql, :timeout_ms

    def analyze?
      @analyze
    end

    def normalized_timeout(value)
      raw = Integer(value, exception: false) || DEFAULT_ANALYZE_TIMEOUT_MS
      [[raw, 1].max, MAX_ANALYZE_TIMEOUT_MS].min
    end

    def validate!
      raise Error, "SQL is required" if sql.blank?
      raise Error, "SQL is too large to explain safely" if sql.bytesize > MAX_SQL_BYTES
      raise Error, "Only a single statement can be explained" if sql.include?(";")
      raise Error, "SQL comments are not accepted for explain requests" if sql.match?(%r{/\*|--|#})
      raise Error, "Only SELECT/CTE statements can be explained" unless normalized_sql.match?(/\A(?:select|with)\b/i)
      raise Error, "Statement contains non-read-only SQL" if normalized_sql.match?(/\b(?:insert|update|delete|replace|alter|create|drop|truncate|call|load|grant|revoke|lock|unlock)\b/i)
    end

    def mysql_explain(connection, adapter)
      if analyze?
        with_mysql_statement_timeout(connection) do
          result(
            adapter: adapter,
            mode: "analyze",
            timeout_ms: timeout_ms,
            rows: select_rows(connection, "EXPLAIN ANALYZE #{normalized_sql}")
          )
        end
      else
        rows = select_rows(connection, "EXPLAIN FORMAT=JSON #{normalized_sql}")
        result(
          adapter: adapter,
          mode: "explain",
          timeout_ms: nil,
          rows: rows,
          json_plan: parse_json_plan(rows)
        )
      end
    end

    def sqlite_explain(connection, adapter)
      result(
        adapter: adapter,
        mode: "explain",
        timeout_ms: nil,
        rows: select_rows(connection, "EXPLAIN QUERY PLAN #{normalized_sql}"),
        warnings: [ "SQLite uses EXPLAIN QUERY PLAN; production MySQL plans can differ." ]
      )
    end

    def result(adapter:, mode:, timeout_ms:, rows:, json_plan: nil, warnings: [])
      Result.new(
        adapter: adapter,
        mode: mode,
        normalized_sql: normalized_sql,
        placeholder_substituted: placeholder_substituted?,
        timeout_ms: timeout_ms,
        rows: rows,
        json_plan: json_plan,
        warnings: warnings
      )
    end

    def select_rows(connection, statement)
      connection.select_all(statement).to_a
    end

    def parse_json_plan(rows)
      raw = rows.first&.values&.first
      JSON.parse(raw) if raw.present?
    rescue JSON::ParserError
      nil
    end

    def with_mysql_statement_timeout(connection)
      connection.execute("SET SESSION max_execution_time = #{timeout_ms}")
      yield
    ensure
      connection.execute("SET SESSION max_execution_time = 0") rescue nil
    end

    def normalized_sql
      @normalized_sql ||= sql.strip.gsub(/\?/, "NULL")
    end

    def placeholder_substituted?
      sql.include?("?")
    end
  end
end
