class AddRetentionAvailableSpaceOverrideToAppSettings < ActiveRecord::Migration[8.1]
  # 0 = unset; RetentionSizeSnapshotJob falls back to automatic available-space
  # inference (SQLite data-root disk usage, or a locally-readable MySQL
  # datadir) and reports source: "unknown" when neither is available.
  def up
    return if column_exists?(:app_settings, :retention_available_space_override_gb)

    add_column :app_settings, :retention_available_space_override_gb, :integer, default: 0, null: false
  end

  def down
    return unless column_exists?(:app_settings, :retention_available_space_override_gb)

    remove_column :app_settings, :retention_available_space_override_gb
  end
end
