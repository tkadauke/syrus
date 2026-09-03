class AddAgentProviderFailoverPolicyToUsers < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:users, :agent_provider_failover_policy)
      add_column :users, :agent_provider_failover_policy, :json
    end
  end
end
