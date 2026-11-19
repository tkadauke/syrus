class CreateLocalBackupObjectHolds < ActiveRecord::Migration[8.1]
  def up
    create_table :local_backups_object_holds, if_not_exists: true do |t|
      t.references :backup, null: false, foreign_key: false
      t.bigint :active_storage_blob_id, null: false
      t.string :storage_key, null: false
      t.timestamps
    end
    unless index_exists?(:local_backups_object_holds, [:backup_id, :active_storage_blob_id], name: "idx_local_backup_holds_backup_blob")
      add_index :local_backups_object_holds, [:backup_id, :active_storage_blob_id], unique: true,
        name: "idx_local_backup_holds_backup_blob"
    end
    add_index :local_backups_object_holds, :active_storage_blob_id unless index_exists?(:local_backups_object_holds, :active_storage_blob_id)
  end

  def down
    drop_table :local_backups_object_holds, if_exists: true
  end
end
