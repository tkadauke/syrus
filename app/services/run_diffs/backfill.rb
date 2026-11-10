module RunDiffs
  # Copies the legacy runs.agent_diff / runs.step_agent_diff columns into
  # run_diffs. Runs in id-range batches, entirely in SQL (INSERT ... SELECT), so
  # the diff text is never loaded into Ruby and is never selected for Runs that
  # will not be copied. Idempotent: Runs that already have a run_diffs row are
  # skipped, so re-running (or racing with the application writing new rows)
  # never duplicates or overwrites.
  class Backfill
    DEFAULT_BATCH_SIZE = 500

    def initialize(connection: ActiveRecord::Base.connection, batch_size: DEFAULT_BATCH_SIZE)
      @connection = connection
      @batch_size = batch_size
    end

    # Returns the number of run_diffs rows inserted.
    def call
      return 0 unless legacy_columns?

      inserted = 0
      each_id_range { |first_id, last_id| inserted += copy_range(first_id, last_id) }
      inserted
    end

    private

    attr_reader :connection, :batch_size

    def legacy_columns?
      connection.column_exists?(:runs, :agent_diff) && connection.column_exists?(:runs, :step_agent_diff)
    end

    def each_id_range
      cursor = 0
      loop do
        ids = connection.select_values(
          "SELECT id FROM runs WHERE id > #{cursor.to_i} ORDER BY id LIMIT #{batch_size.to_i}"
        )
        break if ids.empty?

        yield ids.first.to_i, ids.last.to_i
        cursor = ids.last.to_i
      end
    end

    def copy_range(first_id, last_id)
      now = connection.quote(Time.current.utc.to_fs(:db))
      connection.exec_update(<<~SQL.squish, "RunDiffs::Backfill")
        INSERT INTO run_diffs (run_id, agent_diff, step_agent_diff, created_at, updated_at)
        SELECT runs.id, runs.agent_diff, runs.step_agent_diff, #{now}, #{now}
        FROM runs
        WHERE runs.id BETWEEN #{first_id.to_i} AND #{last_id.to_i}
          AND ((runs.agent_diff IS NOT NULL AND runs.agent_diff <> '')
            OR (runs.step_agent_diff IS NOT NULL AND runs.step_agent_diff <> ''))
          AND NOT EXISTS (SELECT 1 FROM run_diffs WHERE run_diffs.run_id = runs.id)
      SQL
    end
  end
end
