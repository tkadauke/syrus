# What held the rows when a MySQL lock wait timed out.
#
# A LockWaitTimeout names only the transaction that gave up waiting. The one
# holding the lock has, by then, been open for at least
# innodb_lock_wait_timeout, so it is still visible in INNODB_TRX: list the
# long-open transactions with their connection, age and current statement.
# Diagnostics only -- returns [] on any other database and never raises.
module MysqlLockDiagnostics
  LONG_OPEN_TRANSACTION_SECONDS = 15
  MAX_TRANSACTIONS = 10
  MAX_STATEMENT_BYTES = 1_000

  QUERY = <<~SQL.squish.freeze
    SELECT trx.trx_id, trx.trx_mysql_thread_id,
           TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) AS trx_age_seconds,
           trx.trx_rows_locked, trx.trx_query,
           proc.INFO AS processlist_info, proc.TIME AS processlist_time
    FROM information_schema.INNODB_TRX trx
    LEFT JOIN information_schema.PROCESSLIST proc ON proc.ID = trx.trx_mysql_thread_id
    WHERE trx.trx_started <= NOW() - INTERVAL #{LONG_OPEN_TRANSACTION_SECONDS} SECOND
    ORDER BY trx.trx_started
    LIMIT #{MAX_TRANSACTIONS}
  SQL

  module_function

  def snapshot
    connection = ActiveRecord::Base.connection
    return [] unless connection.adapter_name.to_s.match?(/mysql|trilogy/i)

    connection.select_all(QUERY).map do |row|
      statement = row["trx_query"].presence || row["processlist_info"].presence
      {
        "trx_id" => row["trx_id"].to_s,
        "thread_id" => row["trx_mysql_thread_id"],
        "age_seconds" => row["trx_age_seconds"],
        "rows_locked" => row["trx_rows_locked"],
        "statement" => statement.to_s.byteslice(0, MAX_STATEMENT_BYTES).presence
      }.compact
    end
  rescue StandardError => e
    Rails.logger.warn("[MysqlLockDiagnostics] snapshot unavailable: #{e.class}: #{e.message}")
    []
  end

  def lock_wait_error?(exception_class)
    exception_class.to_s.match?(/LockWaitTimeout|Deadlocked|Lock wait timeout/)
  end
end
