class AddPluginManifestSigningKeyToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :plugin_manifest_signing_key, :text unless column_exists?(:app_settings, :plugin_manifest_signing_key)
  end

  def down
    remove_column :app_settings, :plugin_manifest_signing_key if column_exists?(:app_settings, :plugin_manifest_signing_key)
  end
end
