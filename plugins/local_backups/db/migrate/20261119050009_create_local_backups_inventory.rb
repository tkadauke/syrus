class CreateLocalBackupsInventory < ActiveRecord::Migration[8.1]
  def up
    create_table :local_backups_backups, if_not_exists: true do |t|
      t.string :uuid, null: false
      t.string :state, null: false
      t.string :reason
      t.string :artifact_path, null: false
      t.integer :manifest_version, null: false
      t.string :database_adapter
      t.bigint :logical_bytes, null: false, default: 0
      t.bigint :stored_bytes, null: false, default: 0
      t.bigint :blob_count, null: false, default: 0
      t.string :checksum_algorithm
      t.string :checksum
      t.string :verification_state, null: false
      t.string :source_application_version
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :validated_at
      t.datetime :failed_at
      t.datetime :expires_at
      t.boolean :pinned, null: false, default: false
      t.json :encryption_fingerprints
      t.string :error_class
      t.text :error_summary
      t.timestamps
    end
    add_index :local_backups_backups, :uuid, unique: true unless index_exists?(:local_backups_backups, :uuid)
    add_index :local_backups_backups, :state unless index_exists?(:local_backups_backups, :state)
    add_index :local_backups_backups, :completed_at unless index_exists?(:local_backups_backups, :completed_at)

    create_table :local_backups_replications, if_not_exists: true do |t|
      t.references :backup, null: false, index: false, foreign_key: false
      t.string :destination_key, null: false
      t.string :remote_reference
      t.string :state, null: false
      t.string :remote_checksum
      t.datetime :uploaded_at
      t.datetime :verified_at
      t.text :error_summary
      t.timestamps
    end
    add_index :local_backups_replications, [ :backup_id, :destination_key ], unique: true, name: "idx_local_backup_replications_identity" unless index_exists?(:local_backups_replications, [ :backup_id, :destination_key ], name: "idx_local_backup_replications_identity")
  end

  def down
    drop_table :local_backups_replications, if_exists: true
    drop_table :local_backups_backups, if_exists: true
  end
end
