class AddEmergencyLandFieldsToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :emergency_landed_at, :datetime unless column_exists?(:jobs, :emergency_landed_at)
    unless column_exists?(:jobs, :emergency_landed_by_user_id)
      add_column :jobs, :emergency_landed_by_user_id, :bigint
    end
    unless column_exists?(:jobs, :emergency_landed_by_membership_tier)
      add_column :jobs, :emergency_landed_by_membership_tier, :string
    end

    add_index :jobs, :emergency_landed_at unless index_exists?(:jobs, :emergency_landed_at)
    unless index_exists?(:jobs, :emergency_landed_by_user_id)
      add_index :jobs, :emergency_landed_by_user_id
    end
  end
end
