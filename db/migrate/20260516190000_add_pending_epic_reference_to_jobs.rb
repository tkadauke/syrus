class AddPendingEpicReferenceToJobs < ActiveRecord::Migration[8.1]
  # MySQL 8 rejects `default: {}` on JSON columns
  # (`BLOB, TEXT, GEOMETRY or JSON column ... can't have a default
  # value`). Use the standard pattern: add nullable, backfill `{}`
  # for existing rows, then NOT NULL it. The Job model should
  # `after_initialize` seed `{}` for new records so the column
  # stays non-null going forward without a DB default. See
  # docs/agent-guide/conventions.md "JSON columns can't have a DB default
  # on MySQL 8".
  #
  # Idempotent — the column_exists? guard recovers from a partial
  # retry without crashing on `Duplicate column name`.
  def up
    return if column_exists?(:jobs, :pending_epic_reference)

    add_column :jobs, :pending_epic_reference, :json
    execute "UPDATE jobs SET pending_epic_reference = '{}' WHERE pending_epic_reference IS NULL"
    change_column_null :jobs, :pending_epic_reference, false
  end

  def down
    remove_column :jobs, :pending_epic_reference if column_exists?(:jobs, :pending_epic_reference)
  end
end
