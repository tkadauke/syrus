class AddLandedShaToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :landed_sha, :string unless column_exists?(:jobs, :landed_sha)
  end
end
