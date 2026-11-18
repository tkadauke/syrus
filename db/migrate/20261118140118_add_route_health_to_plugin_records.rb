class AddRouteHealthToPluginRecords < ActiveRecord::Migration[8.1]
  def up
    add_column :plugin_records, :request_count, :bigint, default: 0, null: false unless column_exists?(:plugin_records, :request_count)
    add_column :plugin_records, :last_error_at, :datetime unless column_exists?(:plugin_records, :last_error_at)
  end

  def down
    remove_column :plugin_records, :last_error_at if column_exists?(:plugin_records, :last_error_at)
    remove_column :plugin_records, :request_count if column_exists?(:plugin_records, :request_count)
  end
end
