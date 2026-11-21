class AddLeaseToLocalBackupsReplications < ActiveRecord::Migration[8.1]
  def up
    add_column :local_backups_replications, :lease_token, :string unless column_exists?(:local_backups_replications, :lease_token)
    unless column_exists?(:local_backups_replications, :lease_expires_at)
      add_column :local_backups_replications, :lease_expires_at, :datetime
    end
  end

  def down
    remove_column :local_backups_replications, :lease_expires_at if column_exists?(:local_backups_replications, :lease_expires_at)
    remove_column :local_backups_replications, :lease_token if column_exists?(:local_backups_replications, :lease_token)
  end
end
