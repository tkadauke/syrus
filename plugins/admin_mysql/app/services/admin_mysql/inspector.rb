module AdminMysql
  class Inspector
    MAX_LIMIT = 200
    DEFAULT_LIMIT = 50

    class Unavailable < StandardError; end

    class << self
      def mysql?
        ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?("mysql")
      rescue StandardError
        false
      end
    end

    def snapshot(limit: DEFAULT_LIMIT)
      require_mysql!
      limit = clamp_limit(limit)

      PerformanceLogging.suppress do
        {
          available: true,
          generated_at: Time.current.iso8601,
          adapter: connection.adapter_name,
          database: connection.current_database,
          connection_summary: connection_summary,
          variables: variables,
          status: status,
          process_list: process_list(limit: limit),
          statement_digests: statement_digests(limit: [ limit, 25 ].min),
          slow_log: slow_log(limit: [ limit, 25 ].min)
        }
      end
    end

    def kill_query(thread_id)
      require_mysql!
      thread_id = Integer(thread_id)
      raise ArgumentError, "thread_id must be positive" unless thread_id.positive?

      PerformanceLogging.suppress do
        connection.execute("KILL QUERY #{thread_id}")
      end

      {
        killed: true,
        thread_id: thread_id,
        generated_at: Time.current.iso8601
      }
    rescue ArgumentError
      raise
    rescue ActiveRecord::StatementInvalid, Mysql2::Error => e
      {
        killed: false,
        thread_id: thread_id,
        error: {
          class: e.class.name,
          message: e.message
        },
        generated_at: Time.current.iso8601
      }
    end

    private

    def require_mysql!
      raise Unavailable, "Admin MySQL is only available when Syrus is using the mysql2 adapter" unless self.class.mysql?
    end

    def connection
      ActiveRecord::Base.connection
    end

    def select_all(sql)
      connection.exec_query(sql).to_a
    end

    def safe_section
      yield
    rescue StandardError => e
      {
        available: false,
        error: error_payload(e)
      }
    end

    def connection_summary
      status_values = status_hash(%w[
        Threads_connected
        Threads_running
        Max_used_connections
        Aborted_connects
        Connection_errors_max_connections
      ])
      variable_values = variable_hash(%w[
        max_connections
        wait_timeout
        interactive_timeout
      ])
      sleeping = process_count_by_command["Sleep"].to_i

      {
        threads_connected: integer(status_values["Threads_connected"]),
        threads_running: integer(status_values["Threads_running"]),
        max_used_connections: integer(status_values["Max_used_connections"]),
        max_connections: integer(variable_values["max_connections"]),
        sleeping_connections: sleeping,
        aborted_connects: integer(status_values["Aborted_connects"]),
        max_connection_errors: integer(status_values["Connection_errors_max_connections"]),
        wait_timeout: integer(variable_values["wait_timeout"]),
        interactive_timeout: integer(variable_values["interactive_timeout"])
      }
    end

    def process_count_by_command
      select_all("SELECT COMMAND, COUNT(*) AS count FROM information_schema.PROCESSLIST GROUP BY COMMAND")
        .to_h { |row| [ row.fetch("COMMAND").to_s, row.fetch("count").to_i ] }
    end

    def variables
      @variables ||= variable_hash(%w[
        version
        version_comment
        max_connections
        innodb_buffer_pool_size
        innodb_log_file_size
        innodb_redo_log_capacity
        innodb_flush_log_at_trx_commit
        sync_binlog
        slow_query_log
        log_output
        long_query_time
        performance_schema
      ])
    end

    def status
      @status ||= status_hash(%w[
        Threads_connected
        Threads_running
        Max_used_connections
        Slow_queries
        Questions
        Queries
        Uptime
        Created_tmp_tables
        Created_tmp_disk_tables
        Handler_commit
        Handler_rollback
        Innodb_row_lock_current_waits
        Innodb_row_lock_time
        Innodb_row_lock_waits
        Innodb_buffer_pool_reads
        Innodb_buffer_pool_read_requests
        Innodb_data_fsyncs
        Innodb_data_pending_fsyncs
        Innodb_os_log_fsyncs
        Innodb_log_waits
      ])
    end

    def variable_hash(names)
      rows = select_all("SHOW VARIABLES WHERE Variable_name IN (#{quoted_list(names)})")
      rows.to_h { |row| [ row.fetch("Variable_name"), coerce_value(row.fetch("Value")) ] }
    end

    def status_hash(names)
      rows = select_all("SHOW GLOBAL STATUS WHERE Variable_name IN (#{quoted_list(names)})")
      rows.to_h { |row| [ row.fetch("Variable_name"), coerce_value(row.fetch("Value")) ] }
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end

    def process_list(limit:)
      rows = select_all(<<~SQL.squish)
        SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO, 1000) AS INFO
        FROM information_schema.PROCESSLIST
        ORDER BY
          CASE WHEN COMMAND = 'Sleep' THEN 1 ELSE 0 END ASC,
          TIME DESC,
          ID ASC
        LIMIT #{limit}
      SQL

      rows.map do |row|
        {
          id: row["ID"].to_i,
          user: row["USER"],
          host: row["HOST"],
          database: row["DB"],
          command: row["COMMAND"],
          time_seconds: row["TIME"].to_i,
          state: row["STATE"],
          info: row["INFO"]
        }
      end
    end

    def statement_digests(limit:)
      safe_section do
        rows = select_all(<<~SQL.squish)
          SELECT SCHEMA_NAME,
                 DIGEST_TEXT,
                 COUNT_STAR,
                 ROUND(SUM_TIMER_WAIT / 1000000000000, 6) AS total_seconds,
                 ROUND(AVG_TIMER_WAIT / 1000000000000, 6) AS avg_seconds,
                 ROUND(MAX_TIMER_WAIT / 1000000000000, 6) AS max_seconds,
                 SUM_ROWS_SENT,
                 SUM_ROWS_EXAMINED,
                 FIRST_SEEN,
                 LAST_SEEN
          FROM performance_schema.events_statements_summary_by_digest
          WHERE SCHEMA_NAME LIKE #{connection.quote("#{connection.current_database}%")}
          ORDER BY SUM_TIMER_WAIT DESC
          LIMIT #{limit}
        SQL

        {
          available: true,
          rows: rows.map do |row|
            {
              schema_name: row["SCHEMA_NAME"],
              digest_text: row["DIGEST_TEXT"],
              count: row["COUNT_STAR"].to_i,
              total_seconds: float(row["total_seconds"]),
              avg_seconds: float(row["avg_seconds"]),
              max_seconds: float(row["max_seconds"]),
              rows_sent: row["SUM_ROWS_SENT"].to_i,
              rows_examined: row["SUM_ROWS_EXAMINED"].to_i,
              first_seen: row["FIRST_SEEN"]&.iso8601,
              last_seen: row["LAST_SEEN"]&.iso8601
            }
          end
        }
      end
    end

    def slow_log(limit:)
      config = variables.slice("slow_query_log", "log_output", "long_query_time")
      rows = slow_log_rows(limit: limit)

      {
        available: rows[:available],
        config: config,
        rows: rows.fetch(:rows, []),
        error: rows[:error]
      }.compact
    end

    def slow_log_rows(limit:)
      unless variables["slow_query_log"].to_s.upcase == "ON"
        return {
          available: false,
          rows: [],
          error: {
            message: "slow_query_log is off",
            hint: "Enable MySQL slow query logging to collect live slow-log rows.",
            setup_sql: [
              "SET GLOBAL slow_query_log = 'ON';",
              "SET GLOBAL long_query_time = 1;"
            ]
          }
        }
      end

      unless variables["log_output"].to_s.upcase.include?("TABLE")
        return {
          available: false,
          rows: [],
          error: {
            message: "log_output does not include TABLE",
            hint: "Syrus can only read slow-log rows through mysql.slow_log. Add TABLE to log_output, then grant read access.",
            setup_sql: [
              "SET GLOBAL log_output = 'TABLE';",
              "GRANT SELECT ON mysql.slow_log TO CURRENT_USER;"
            ]
          }
        }
      end

      safe_section do
        rows = select_all(<<~SQL.squish)
          SELECT start_time, user_host, query_time, lock_time, rows_sent, rows_examined, db, LEFT(sql_text, 1000) AS sql_text
          FROM mysql.slow_log
          ORDER BY start_time DESC
          LIMIT #{limit}
        SQL

        {
          available: true,
          rows: rows.map do |row|
            {
              start_time: row["start_time"]&.iso8601,
              user_host: row["user_host"],
              query_time: row["query_time"].to_s,
              lock_time: row["lock_time"].to_s,
              rows_sent: row["rows_sent"].to_i,
              rows_examined: row["rows_examined"].to_i,
              database: row["db"],
              sql_text: row["sql_text"]
            }
          end
        }
      end
    end

    def clamp_limit(value)
      [[value.to_i, 1].max, MAX_LIMIT].min
    end

    def coerce_value(value)
      text = value.to_s
      return text.to_i if text.match?(/\A\d+\z/)
      return text.to_f if text.match?(/\A\d+\.\d+\z/)

      text
    end

    def integer(value)
      Integer(value, exception: false)
    end

    def float(value)
      Float(value, exception: false)
    end

    def error_payload(error)
      message = error.message.to_s
      payload = {
        class: error.class.name,
        message: message
      }

      if message.include?("command denied") && (message.include?("performance_schema") || message.include?("events_statements_summary_by_digest"))
        payload[:message] = "The Syrus MySQL user cannot read Performance Schema statement digests."
        payload[:hint] = "Grant SELECT on performance_schema.events_statements_summary_by_digest to show aggregate statement timing."
        payload[:setup_sql] = [ "GRANT SELECT ON performance_schema.events_statements_summary_by_digest TO CURRENT_USER;" ]
      elsif message.include?("command denied") && (message.include?("mysql.slow_log") || message.include?("slow_log"))
        payload[:message] = "The Syrus MySQL user cannot read mysql.slow_log."
        payload[:hint] = "Grant SELECT on mysql.slow_log to show table-backed slow query log rows."
        payload[:setup_sql] = [ "GRANT SELECT ON mysql.slow_log TO CURRENT_USER;" ]
      end

      payload
    end
  end
end
