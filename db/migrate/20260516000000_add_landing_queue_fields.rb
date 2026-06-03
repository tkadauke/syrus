class AddLandingQueueFields < ActiveRecord::Migration[8.1]
  # AddApprovalStateToJobs also owns `approved_at`, but that migration sorts
  # later. Keep this migration self-sufficient so a fresh database can create
  # the landing queue index during a from-zero migrate.
  def up
    add_column :jobs, :approved_at, :datetime unless column_exists?(:jobs, :approved_at)
    add_column :jobs, :landing_failure_reason, :text unless column_exists?(:jobs, :landing_failure_reason)
    add_column :users, :landing_paused, :boolean, default: false, null: false unless column_exists?(:users, :landing_paused)

    add_index :jobs, [ :state, :approved_at, :id ] unless index_exists?(:jobs, [ :state, :approved_at, :id ])
    add_index :users, :landing_paused unless index_exists?(:users, :landing_paused)
  end

  def down
    remove_index :jobs, [ :state, :approved_at, :id ] if index_exists?(:jobs, [ :state, :approved_at, :id ])
    remove_index :users, :landing_paused if index_exists?(:users, :landing_paused)
    remove_column :users, :landing_paused if column_exists?(:users, :landing_paused)
    remove_column :jobs, :landing_failure_reason if column_exists?(:jobs, :landing_failure_reason)
  end
end
