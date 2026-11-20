class AddApplyProcessesToPluginDesiredStates < ActiveRecord::Migration[8.1]
  def change
    add_column :plugin_desired_states, :apply_processes, :json unless column_exists?(:plugin_desired_states, :apply_processes)
  end
end
