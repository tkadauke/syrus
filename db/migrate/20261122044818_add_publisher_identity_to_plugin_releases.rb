class AddPublisherIdentityToPluginReleases < ActiveRecord::Migration[8.1]
  def up
    add_column :plugin_releases, :publisher_key_fingerprint, :string unless column_exists?(:plugin_releases, :publisher_key_fingerprint)
    add_column :plugin_releases, :signature, :text unless column_exists?(:plugin_releases, :signature)
    add_index :plugin_releases, :publisher_key_fingerprint unless index_exists?(:plugin_releases, :publisher_key_fingerprint)
    execute <<~SQL.squish
      UPDATE plugin_releases
      SET trust_label = CASE
        WHEN trust_label IN ('bundled', 'official') THEN 'official'
        WHEN trust_label IN ('reviewed', 'audited', 'verified') THEN 'verified'
        WHEN trust_label = 'community' THEN 'community'
        ELSE 'unsigned_local'
      END
    SQL
  end

  def down
    remove_index :plugin_releases, :publisher_key_fingerprint if index_exists?(:plugin_releases, :publisher_key_fingerprint)
    remove_column :plugin_releases, :signature if column_exists?(:plugin_releases, :signature)
    remove_column :plugin_releases, :publisher_key_fingerprint if column_exists?(:plugin_releases, :publisher_key_fingerprint)
  end
end
