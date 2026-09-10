class AddRunListingHotPathIndexes < ActiveRecord::Migration[8.1]
  def up
    remove_index :runs, name: "idx_runs_updated_latest", if_exists: true

    add_column :runs, :effective_at, :datetime, if_not_exists: true

    execute(<<~SQL.squish)
      UPDATE runs
      SET effective_at = COALESCE(finished_at, started_at, created_at)
      WHERE effective_at IS NULL
    SQL

    change_column_null :runs, :effective_at, false

    add_index :runs,
      [ :started_at, :id ],
      name: "idx_runs_started_latest",
      if_not_exists: true

    add_index :runs,
      [ :effective_at, :id ],
      name: "idx_runs_effective_latest",
      if_not_exists: true
  end

  def down
    remove_index :runs, name: "idx_runs_effective_latest", if_exists: true
    remove_index :runs, name: "idx_runs_started_latest", if_exists: true
    remove_column :runs, :effective_at, if_exists: true
  end
end
