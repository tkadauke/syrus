class AddSkipPrepareToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :skip_prepare, :boolean, null: false, default: false unless column_exists?(:jobs, :skip_prepare)
  end
end
