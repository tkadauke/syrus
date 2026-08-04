class AddLandingBlockerOverrideToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :landing_blocker_override_key, :string unless column_exists?(:jobs, :landing_blocker_override_key)
    add_column :jobs, :landing_blocker_override_reason, :text unless column_exists?(:jobs, :landing_blocker_override_reason)
    add_column :jobs, :landing_blocker_override_requested_at, :datetime unless column_exists?(:jobs, :landing_blocker_override_requested_at)
    unless column_exists?(:jobs, :landing_blocker_override_requested_by_user_id)
      add_column :jobs, :landing_blocker_override_requested_by_user_id, :integer
    end
    add_column :jobs, :landing_blocker_override_used_at, :datetime unless column_exists?(:jobs, :landing_blocker_override_used_at)

    add_index :jobs, :landing_blocker_override_key unless index_exists?(:jobs, :landing_blocker_override_key)
    unless index_exists?(:jobs, :landing_blocker_override_requested_by_user_id)
      add_index :jobs, :landing_blocker_override_requested_by_user_id
    end
  end
end
