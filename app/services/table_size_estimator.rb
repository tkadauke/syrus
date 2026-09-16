# Fast, approximate row-count and byte-size estimation for a single table.
# Deliberately never runs COUNT(*) or a full table scan -- both are
# unacceptable on tables large enough for retention tuning to matter.
class TableSizeEstimator
  Result = Data.define(:table_name, :row_count_estimate, :byte_size_estimate) do
    def as_json(*)
      {
        table_name: table_name,
        row_count_estimate: row_count_estimate,
        byte_size_estimate: byte_size_estimate
      }
    end
  end

  class << self
    def estimate(table_name)
      mysql? ? estimate_mysql(table_name) : estimate_sqlite(table_name)
    end

    private

    def mysql?
      ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
    end

    # information_schema.TABLES' TABLE_ROWS and DATA_LENGTH/INDEX_LENGTH are
    # InnoDB engine estimates, not exact counts -- they can drift from the
    # true values between ANALYZE TABLE runs. That's an accepted tradeoff for
    # a sizing dashboard; it avoids a COUNT(*) scan on tables that can hold
    # millions of rows.
    def estimate_mysql(table_name)
      row = ActiveRecord::Base.connection.select_one(<<~SQL.squish, "TableSizeEstimator")
        SELECT TABLE_ROWS AS row_count, (DATA_LENGTH + INDEX_LENGTH) AS byte_size
        FROM information_schema.TABLES
        WHERE table_schema = DATABASE() AND table_name = #{ActiveRecord::Base.connection.quote(table_name)}
      SQL

      Result.new(
        table_name: table_name,
        row_count_estimate: row&.[]("row_count")&.to_i,
        byte_size_estimate: row&.[]("byte_size")&.to_i
      )
    end

    def estimate_sqlite(table_name)
      Result.new(
        table_name: table_name,
        row_count_estimate: sqlite_row_count_estimate(table_name),
        byte_size_estimate: sqlite_byte_size_estimate(table_name)
      )
    end

    # MAX(rowid) is a fast proxy for row count -- it reads the table's
    # rightmost index leaf instead of scanning every row. It undercounts
    # after heavy deletes (rowid isn't reused until VACUUM/reset), which is
    # an accepted tradeoff for an estimate rather than an exact count.
    def sqlite_row_count_estimate(table_name)
      quoted_table = ActiveRecord::Base.connection.quote_table_name(table_name)
      ActiveRecord::Base.connection.select_value("SELECT MAX(rowid) FROM #{quoted_table}")&.to_i
    rescue ActiveRecord::StatementInvalid
      nil
    end

    # dbstat is a virtual table that some SQLite builds are compiled without
    # (SQLITE_ENABLE_DBSTAT_VTAB); feature-detect rather than assume it's
    # there, and fall back to no byte estimate when it isn't.
    def sqlite_byte_size_estimate(table_name)
      return nil unless sqlite_dbstat_available?

      ActiveRecord::Base.connection.select_value(
        "SELECT SUM(pgsize) FROM dbstat WHERE name = #{ActiveRecord::Base.connection.quote(table_name)}"
      )&.to_i
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def sqlite_dbstat_available?
      ActiveRecord::Base.connection.select_value("SELECT 1 FROM dbstat LIMIT 1")
      true
    rescue ActiveRecord::StatementInvalid
      false
    end
  end
end
