class AddExperimentalPluginGating < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :experimental_plugins_enabled, :boolean, default: false, null: false unless column_exists?(:app_settings, :experimental_plugins_enabled)
    add_column :plugin_records, :experimental, :boolean, default: false, null: false unless column_exists?(:plugin_records, :experimental)
  end
end
