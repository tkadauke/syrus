class AddRunListingHotPathIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :runs,
      [ :started_at, :id ],
      name: "idx_runs_started_latest",
      if_not_exists: true

    add_index :runs,
      [ :updated_at, :id ],
      name: "idx_runs_updated_latest",
      if_not_exists: true
  end
end
