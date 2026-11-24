class AddRuntimeImageOperations < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_audit_events, if_not_exists: true do |t|
      t.bigint :runtime_image_id
      t.bigint :runtime_image_namespace_id
      t.string :event_type, null: false, limit: 64
      t.string :outcome, null: false, limit: 32
      t.string :digest, limit: 191
      t.string :actor, limit: 100
      t.json :details
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end
    execute "UPDATE runtime_image_audit_events SET details = '{}' WHERE details IS NULL"
    unless index_exists?(:runtime_image_audit_events, %i[event_type occurred_at], name: "idx_ri_audit_type_time")
      add_index :runtime_image_audit_events, %i[event_type occurred_at], name: "idx_ri_audit_type_time"
    end
    unless index_exists?(:runtime_image_audit_events, %i[runtime_image_id occurred_at], name: "idx_ri_audit_image_time")
      add_index :runtime_image_audit_events, %i[runtime_image_id occurred_at], name: "idx_ri_audit_image_time"
    end
    unless index_exists?(:runtime_image_audit_events, :occurred_at, name: "idx_ri_audit_time")
      add_index :runtime_image_audit_events, :occurred_at, name: "idx_ri_audit_time"
    end

    unless column_exists?(:runtime_images, :cleanup_failure_count)
      add_column :runtime_images, :cleanup_failure_count, :integer, null: false, default: 0
    end
    add_column :runtime_images, :cleanup_failed_at, :datetime unless column_exists?(:runtime_images, :cleanup_failed_at)
    add_column :runtime_images, :cleanup_last_error, :string, limit: 500 unless column_exists?(:runtime_images, :cleanup_last_error)
  end

  def down
    drop_table :runtime_image_audit_events, if_exists: true
    remove_column :runtime_images, :cleanup_last_error if column_exists?(:runtime_images, :cleanup_last_error)
    remove_column :runtime_images, :cleanup_failed_at if column_exists?(:runtime_images, :cleanup_failed_at)
    remove_column :runtime_images, :cleanup_failure_count if column_exists?(:runtime_images, :cleanup_failure_count)
  end
end
