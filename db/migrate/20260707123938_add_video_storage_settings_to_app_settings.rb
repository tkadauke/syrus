class AddVideoStorageSettingsToAppSettings < ActiveRecord::Migration[8.1]
  # Walkthrough-video media management. retention_days bounds how long the
  # stored (transcoded) video is kept for retry; storage_budget_mb is the
  # instance-wide ceiling on total walkthrough video bytes, enforced LRU by
  # VideoWalkthroughs::PruneJob (0 = unlimited). The analysis + screenshots
  # always persist — only the heavy video is subject to these.
  def up
    unless column_exists?(:app_settings, :video_retention_days)
      add_column :app_settings, :video_retention_days, :integer, default: 7, null: false
    end
    unless column_exists?(:app_settings, :video_storage_budget_mb)
      add_column :app_settings, :video_storage_budget_mb, :integer, default: 2048, null: false
    end
  end

  def down
    remove_column :app_settings, :video_retention_days if column_exists?(:app_settings, :video_retention_days)
    remove_column :app_settings, :video_storage_budget_mb if column_exists?(:app_settings, :video_storage_budget_mb)
  end
end
