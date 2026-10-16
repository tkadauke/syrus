class AddPreparedLayerCacheGbToAppSettings < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:app_settings, :prepared_layer_cache_gb)

    add_column :app_settings, :prepared_layer_cache_gb, :integer, default: 100, null: false
  end

  def down
    remove_column :app_settings, :prepared_layer_cache_gb if column_exists?(:app_settings, :prepared_layer_cache_gb)
  end
end
