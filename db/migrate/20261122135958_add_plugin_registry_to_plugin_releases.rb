class AddPluginRegistryToPluginReleases < ActiveRecord::Migration[8.1]
  def up = add_reference(:plugin_releases, :plugin_registry, null: true, foreign_key: false) unless column_exists?(:plugin_releases, :plugin_registry_id)
  def down = remove_reference(:plugin_releases, :plugin_registry) if column_exists?(:plugin_releases, :plugin_registry_id)
end
