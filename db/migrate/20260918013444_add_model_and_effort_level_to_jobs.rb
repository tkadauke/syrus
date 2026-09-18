class AddModelAndEffortLevelToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :model, :string unless column_exists?(:jobs, :model)
    add_column :jobs, :effort_level, :string unless column_exists?(:jobs, :effort_level)
  end

  def down
    remove_column :jobs, :effort_level if column_exists?(:jobs, :effort_level)
    remove_column :jobs, :model if column_exists?(:jobs, :model)
  end
end
