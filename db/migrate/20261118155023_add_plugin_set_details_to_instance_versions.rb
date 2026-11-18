class AddPluginSetDetailsToInstanceVersions < ActiveRecord::Migration[8.1]
  def up
    add_column :instance_versions, :plugin_set_details, :json unless column_exists?(:instance_versions, :plugin_set_details)
  end

  def down
    remove_column :instance_versions, :plugin_set_details if column_exists?(:instance_versions, :plugin_set_details)
  end
end
