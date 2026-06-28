class AddTitlePendingToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :title_pending, :boolean, default: false, null: false unless column_exists?(:jobs, :title_pending)
  end

  def down
    remove_column :jobs, :title_pending if column_exists?(:jobs, :title_pending)
  end
end
