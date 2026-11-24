class CreateRuntimeImageRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_namespaces, if_not_exists: true do |t|
      t.string :name, null: false, limit: 191
      t.string :owner_kind, null: false, limit: 100
      t.string :owner_ref, null: false, limit: 191
      t.string :provider_key, null: false, limit: 100
      t.integer :retention_days
      t.timestamps
    end
    add_index :runtime_image_namespaces, :name, unique: true, name: "idx_runtime_image_namespaces_name" unless index_exists?(:runtime_image_namespaces, :name, name: "idx_runtime_image_namespaces_name")
    add_index :runtime_image_namespaces, %i[owner_kind owner_ref], name: "idx_runtime_image_namespaces_owner" unless index_exists?(:runtime_image_namespaces, %i[owner_kind owner_ref], name: "idx_runtime_image_namespaces_owner")

    create_table :runtime_images, if_not_exists: true do |t|
      t.bigint :runtime_image_namespace_id, null: false
      t.string :digest, null: false, limit: 191
      t.string :platform, null: false, limit: 64, default: "linux/amd64"
      t.string :locator, limit: 1000
      t.string :source_kind, null: false, limit: 100
      t.string :source_ref, null: false, limit: 191
      t.string :source_digest, limit: 191
      t.json :provenance
      t.string :availability, null: false, limit: 32, default: "pending"
      t.datetime :published_at
      t.datetime :revoked_at
      t.string :revoked_reason, limit: 500
      t.string :retention_state, null: false, limit: 32, default: "default"
      t.datetime :retain_until
      t.string :retention_reason, limit: 500
      t.datetime :deleted_at
      t.timestamps
    end
    execute "UPDATE runtime_images SET provenance = '{}' WHERE provenance IS NULL"
    change_column_null :runtime_images, :provenance, false
    add_index :runtime_images, %i[runtime_image_namespace_id digest platform], unique: true, name: "idx_runtime_images_identity" unless index_exists?(:runtime_images, %i[runtime_image_namespace_id digest platform], name: "idx_runtime_images_identity")
    add_index :runtime_images, %i[source_kind source_ref], name: "idx_runtime_images_source" unless index_exists?(:runtime_images, %i[source_kind source_ref], name: "idx_runtime_images_source")
    add_index :runtime_images, %i[availability retention_state], name: "idx_runtime_images_state" unless index_exists?(:runtime_images, %i[availability retention_state], name: "idx_runtime_images_state")
  end

  def down
    drop_table :runtime_images, if_exists: true
    drop_table :runtime_image_namespaces, if_exists: true
  end
end
