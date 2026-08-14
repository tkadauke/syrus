class RemoveVisualReviewEnabledFromAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :app_settings, :visual_review_enabled if column_exists?(:app_settings, :visual_review_enabled)
  end

  def down
    unless column_exists?(:app_settings, :visual_review_enabled)
      add_column :app_settings, :visual_review_enabled, :boolean, default: false, null: false
    end
  end
end
