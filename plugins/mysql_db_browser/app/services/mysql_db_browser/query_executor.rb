require "mysql2"

module MysqlDbBrowser
  # Executes ad hoc SQL (raw Query-tab statements, or a content-grid SELECT
  # built server-side) against an external MysqlConnection with the same
  # guardrail posture as AdminMysql::Inspector: a statement-timeout hint,
  # row-limit clamping (via streaming - never buffers more than limit+1
  # rows), long-value truncation via safe_byteslice, and structured
  # GRANT-error hints. Every attempt, successful or not, is recorded to
  # MysqlQueryAudit.
  #
  # Read-only is the default posture: anything that isn't a SELECT (or a
  # SELECT-only WITH ... CTE) is rejected unless the connection has
  # explicitly opted into writes (MysqlConnection#allow_writes).
  class QueryExecutor
    CONNECT_TIMEOUT_SECONDS = 5
    QUERY_TIMEOUT_MS = 5_000
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500
    MAX_VALUE_BYTES = 2_000

    class Unavailable < StandardError; end
    class WriteNotAllowed < StandardError; end
    class BlankStatement < StandardError; end

    class_attribute :client_factory, default: ->(options) { Mysql2::Client.new(**options) }

    def initialize(connection)
      @connection = connection
    end

    # Raw-statement path: the Query tab and the Live-diagnostics tab's
    # canned system-table SELECTs. Rejects non-SELECT statements up front,
    # before ever opening a connection, unless the connection allows writes.
    def execute(sql, user:, limit: DEFAULT_LIMIT)
      statement = sql.to_s.strip
      raise BlankStatement, "SQL statement is blank" if statement.blank?

      read_only = read_only_statement?(statement)
      if !read_only && !connection.allow_writes?
        audit!(statement: statement, read_only: read_only, user: user, success: false, error_message: "Rejected: this connection is read-only.")
        raise WriteNotAllowed, "This connection is read-only. Enable write access on the connection to run non-SELECT statements."
      end

      with_client { |client| run_and_audit(client, statement, read_only: read_only, user: user, limit: limit) }
    end

    # Content-grid path: the caller builds the final SELECT from the
    # yielded, already-connected client (so a FilterTreeSqlCompiler can
    # escape WHERE-clause values through the same client that will run the
    # query). Always read-only by construction - there is no code path for
    # the block to hand back anything but a SELECT.
    def execute_select(user:, limit: DEFAULT_LIMIT)
      with_client do |client|
        statement = yield(client).to_s.strip
        raise BlankStatement, "SQL statement is blank" if statement.blank?

        run_and_audit(client, statement, read_only: true, user: user, limit: limit)
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

    def run_and_audit(client, statement, read_only:, user:, limit:)
      started_at = monotonic_now
      payload = read_only ? run_select(client, statement, clamp_limit(limit)) : run_write(client, statement)
      duration_ms = elapsed_ms(started_at)
      audit!(statement: statement, read_only: read_only, user: user, success: true, row_count: payload[:row_count], duration_ms: duration_ms)
      payload.merge(statement: statement, read_only: read_only, duration_ms: duration_ms, generated_at: Time.current.iso8601)
    rescue Mysql2::Error => e
      duration_ms = elapsed_ms(started_at)
      audit!(statement: statement, read_only: read_only, user: user, success: false, error_message: e.message, duration_ms: duration_ms)
      { available: false, statement: statement, read_only: read_only, error: error_payload(e), duration_ms: duration_ms, generated_at: Time.current.iso8601 }
    end

    def read_only_statement?(statement)
      statement.match?(/\A(SELECT|WITH)\b/i)
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

    def run_select(client, statement, limit)
      result = client.query(mysql_timeout_hint(statement), stream: true, cache_rows: false, as: :hash)
      columns = result.fields
      rows = []

      result.each do |row|
        rows << row
        next unless rows.length > limit

        client.abandon_results! if client.respond_to?(:abandon_results!)
        break
      end

      truncated = rows.length > limit
      limited_rows = rows.first(limit).map { |row| truncate_row(row) }

      {
        available: true,
        columns: columns.presence || limited_rows.first&.keys || [],
        rows: limited_rows,
        row_count: limited_rows.length,
        truncated: truncated
      }
    end

    def run_write(client, statement)
      client.query(statement)

      {
        available: true,
        columns: [],
        rows: [],
        row_count: client.affected_rows,
        truncated: false,
        affected_rows: client.affected_rows
      }
    end

    # Guards against a slow/unreachable external host hanging a request,
    # same posture as SchemaInspector#mysql_timeout_hint. Only literal
    # SELECT statements get the hint - MySQL's optimizer hint syntax must
    # immediately follow the SELECT keyword, so a `WITH ... SELECT` CTE is
    # left unhinted rather than mangled.
    def mysql_timeout_hint(sql)
      sql.to_s.sub(/\ASELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{QUERY_TIMEOUT_MS}) */")
    end

    def clamp_limit(value)
      [ [ value.to_i, 1 ].max, MAX_LIMIT ].min
    end

    def truncate_row(row)
      row.transform_values { |value| truncate_value(value) }
    end

    def truncate_value(value)
      return value unless value.is_a?(String)
      return value if value.bytesize <= MAX_VALUE_BYTES

      "#{value.safe_byteslice(0, MAX_VALUE_BYTES)}…"
    end

    def error_payload(error)
      message = error.message.to_s
      payload = { class: error.class.name, message: message }

      if message.include?("command denied")
        payload[:hint] = "This MySQL user lacks privileges for this statement. Grant the required access and try again."
      elsif message.include?("MAX_EXECUTION_TIME")
        payload[:hint] = "The query exceeded its #{QUERY_TIMEOUT_MS}ms statement timeout. Narrow it with a more selective WHERE clause or LIMIT."
      end

      payload
    end

    def audit!(statement:, read_only:, user:, success:, row_count: nil, error_message: nil, duration_ms: nil)
      MysqlQueryAudit.create!(
        mysql_connection: connection,
        user: user,
        statement: statement,
        read_only: read_only,
        success: success,
        row_count: row_count,
        error_message: error_message,
        duration_ms: duration_ms
      )
    rescue StandardError => e
      Rails.logger.error("MysqlDbBrowser::QueryExecutor audit failed: #{e.class}: #{e.message}")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_now - started_at) * 1000).round
    end
  end
end
