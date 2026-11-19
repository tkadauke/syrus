class CreatePluginDesiredState < ActiveRecord::Migration[8.1]
  def up
    create_table :plugin_releases, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :version, null: false
      t.string :content_digest, null: false
      t.string :source, null: false
      t.string :trust_label, null: false
      t.bigint :uploaded_by_id
      t.bigint :size_bytes, null: false
      t.timestamps
    end
    add_index :plugin_releases, [ :name, :version, :content_digest ], unique: true, name: "idx_plugin_releases_identity" unless index_exists?(:plugin_releases, [ :name, :version, :content_digest ], name: "idx_plugin_releases_identity")
    add_index :plugin_releases, :content_digest unless index_exists?(:plugin_releases, :content_digest)
    add_index :plugin_releases, :uploaded_by_id unless index_exists?(:plugin_releases, :uploaded_by_id)

    create_table :plugin_installations, if_not_exists: true do |t|
      t.string :plugin_name, null: false
      t.bigint :plugin_release_id, null: false
      t.boolean :enabled_for_sync, null: false, default: true
      t.boolean :fleet_quarantined, null: false, default: false
      t.json :roles
      t.datetime :desired_since, null: false
      t.timestamps
    end
    add_index :plugin_installations, :plugin_name, unique: true unless index_exists?(:plugin_installations, :plugin_name, unique: true)
    add_index :plugin_installations, :plugin_release_id unless index_exists?(:plugin_installations, :plugin_release_id)

    create_table :plugin_desired_states, if_not_exists: true do |t|
      t.integer :singleton_key, null: false
      t.bigint :revision, null: false, default: 0
      t.timestamps
    end
    add_index :plugin_desired_states, :singleton_key, unique: true unless index_exists?(:plugin_desired_states, :singleton_key, unique: true)
  end

  def down
    drop_table :plugin_desired_states, if_exists: true
    drop_table :plugin_installations, if_exists: true
    drop_table :plugin_releases, if_exists: true
  end
end
