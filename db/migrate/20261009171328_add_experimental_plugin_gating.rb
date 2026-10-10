class AddExperimentalPluginGating < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:app_settings, :experimental_plugins_enabled) && !column_exists?(:app_settings, :beta_mode_enabled)
      rename_column :app_settings, :experimental_plugins_enabled, :beta_mode_enabled
    end
    add_column :app_settings, :beta_mode_enabled, :boolean, default: false, null: false unless column_exists?(:app_settings, :beta_mode_enabled)
    add_column :plugin_records, :experimental, :boolean, default: false, null: false unless column_exists?(:plugin_records, :experimental)
    add_column :features, :experimental, :boolean, default: false, null: false unless column_exists?(:features, :experimental)
  end

  def down
    remove_column :features, :experimental if column_exists?(:features, :experimental)
    remove_column :plugin_records, :experimental if column_exists?(:plugin_records, :experimental)

    if column_exists?(:app_settings, :beta_mode_enabled) && !column_exists?(:app_settings, :experimental_plugins_enabled)
      rename_column :app_settings, :beta_mode_enabled, :experimental_plugins_enabled
    end
  end
end
