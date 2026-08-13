class AddVisualReviewEnabledToAppSettings < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:app_settings, :visual_review_enabled)
      add_column :app_settings, :visual_review_enabled, :boolean, default: false, null: false
    end
  end

  def down
    remove_column :app_settings, :visual_review_enabled if column_exists?(:app_settings, :visual_review_enabled)
  end
end
