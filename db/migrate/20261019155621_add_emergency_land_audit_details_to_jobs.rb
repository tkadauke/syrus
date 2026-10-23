class AddEmergencyLandAuditDetailsToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :emergency_land_source_sha, :string unless column_exists?(:jobs, :emergency_land_source_sha)
    add_column :jobs, :emergency_land_skipped_controls, :json unless column_exists?(:jobs, :emergency_land_skipped_controls)
  end
end
