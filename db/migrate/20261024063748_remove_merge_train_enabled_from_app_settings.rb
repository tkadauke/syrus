class RemoveMergeTrainEnabledFromAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :app_settings, :merge_train_enabled, :boolean if column_exists?(:app_settings, :merge_train_enabled)
  end

  def down
    return if column_exists?(:app_settings, :merge_train_enabled)

    add_column :app_settings, :merge_train_enabled, :boolean, default: false, null: false
  end
end
