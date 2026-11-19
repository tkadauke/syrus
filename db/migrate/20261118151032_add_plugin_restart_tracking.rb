class AddPluginRestartTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :plugin_desired_states, :apply_revision, :integer unless column_exists?(:plugin_desired_states, :apply_revision)
    add_column :plugin_desired_states, :apply_requested_at, :datetime unless column_exists?(:plugin_desired_states, :apply_requested_at)
    add_column :instance_versions, :plugin_set_revision, :integer unless column_exists?(:instance_versions, :plugin_set_revision)
    add_column :instance_versions, :plugin_set_digest, :string unless column_exists?(:instance_versions, :plugin_set_digest)
  end
end
