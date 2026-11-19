class AddPublisherFingerprintToPluginReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :plugin_releases, :publisher_fingerprint, :string unless column_exists?(:plugin_releases, :publisher_fingerprint)
    add_index :plugin_releases, :publisher_fingerprint unless index_exists?(:plugin_releases, :publisher_fingerprint)
    add_index :plugin_releases, :publisher_fingerprint unless index_exists?(:plugin_releases, :publisher_fingerprint)
  end
end
