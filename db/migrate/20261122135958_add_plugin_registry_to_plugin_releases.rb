class AddPluginRegistryToPluginReleases < ActiveRecord::Migration[8.1]
  def up
    add_reference(:plugin_releases, :plugin_registry, null: true, foreign_key: false) unless column_exists?(:plugin_releases, :plugin_registry_id)
    remove_index :plugin_releases, name: "idx_plugin_releases_identity" if index_exists?(:plugin_releases, name: "idx_plugin_releases_identity")
    add_index :plugin_releases, %i[name version content_digest plugin_registry_id], unique: true,
      name: "idx_plugin_releases_identity" unless index_exists?(:plugin_releases, name: "idx_plugin_releases_identity")
  end

  def down
    remove_index :plugin_releases, name: "idx_plugin_releases_identity" if index_exists?(:plugin_releases, name: "idx_plugin_releases_identity")
    add_index :plugin_releases, %i[name version content_digest], unique: true,
      name: "idx_plugin_releases_identity" unless index_exists?(:plugin_releases, name: "idx_plugin_releases_identity")
    remove_reference :plugin_releases, :plugin_registry if column_exists?(:plugin_releases, :plugin_registry_id)
  end
end
