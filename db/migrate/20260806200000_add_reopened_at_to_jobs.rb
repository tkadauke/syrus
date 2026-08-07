class AddReopenedAtToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :reopened_at, :datetime unless column_exists?(:jobs, :reopened_at)
  end
end
