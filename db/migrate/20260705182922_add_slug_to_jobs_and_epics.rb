class AddSlugToJobsAndEpics < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :slug, :string unless column_exists?(:jobs, :slug)
    add_column :epics, :slug, :string unless column_exists?(:epics, :slug)
    add_index :jobs, :slug, unique: true unless index_exists?(:jobs, :slug)
    add_index :epics, :slug, unique: true unless index_exists?(:epics, :slug)
  end

  def down
    remove_index :jobs, :slug if index_exists?(:jobs, :slug)
    remove_index :epics, :slug if index_exists?(:epics, :slug)
    remove_column :jobs, :slug if column_exists?(:jobs, :slug)
    remove_column :epics, :slug if column_exists?(:epics, :slug)
  end
end
