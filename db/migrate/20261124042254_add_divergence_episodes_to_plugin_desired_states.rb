class AddDivergenceEpisodesToPluginDesiredStates < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:plugin_desired_states, :divergence_episodes)

    add_column :plugin_desired_states, :divergence_episodes, :json
  end
end
