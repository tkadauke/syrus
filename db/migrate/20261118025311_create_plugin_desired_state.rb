class CreatePluginDesiredState < ActiveRecord::Migration[8.1]
  def up
    create_table :plugin_releases, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :version, null: false
      t.string :content_digest, null: false
      t.string :source, null: false
      t.string :trust_label, null: false
      t.references :uploaded_by_user, null: true, foreign_key: false
      t.bigint :size_bytes, null: false
      t.timestamps
    end
    add_index :plugin_releases, %i[name version content_digest], unique: true, name: "index_plugin_releases_identity" unless index_exists?(:plugin_releases, %i[name version content_digest], name: "index_plugin_releases_identity")

    create_table :plugin_installations, if_not_exists: true do |t|
      t.string :plugin_name, null: false
      t.references :plugin_release, null: false, foreign_key: false
      t.boolean :enabled_for_sync, null: false, default: true
      t.boolean :fleet_quarantined, null: false, default: false
      t.json :roles
      t.datetime :desired_since, null: false
      t.timestamps
    end
    add_index :plugin_installations, :plugin_name, unique: true unless index_exists?(:plugin_installations, :plugin_name, unique: true)

    create_table :plugin_desired_state_revisions, if_not_exists: true do |t|
      t.integer :singleton_key, null: false, default: 1
      t.bigint :revision, null: false, default: 0
      t.timestamps
    end
    add_index :plugin_desired_state_revisions, :singleton_key, unique: true unless index_exists?(:plugin_desired_state_revisions, :singleton_key, unique: true)

    add_column :app_settings, :plugin_manifest_private_key_pem, :text unless column_exists?(:app_settings, :plugin_manifest_private_key_pem)
  end

  def down
    remove_column :app_settings, :plugin_manifest_private_key_pem if column_exists?(:app_settings, :plugin_manifest_private_key_pem)
    drop_table :plugin_desired_state_revisions, if_exists: true
    drop_table :plugin_installations, if_exists: true
    drop_table :plugin_releases, if_exists: true
  end
end
