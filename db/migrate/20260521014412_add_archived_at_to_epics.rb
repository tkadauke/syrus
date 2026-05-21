class AddArchivedAtToEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :epics, :archived_at, :datetime unless column_exists?(:epics, :archived_at)
  end

  def down
    remove_column :epics, :archived_at if column_exists?(:epics, :archived_at)
  end
end
