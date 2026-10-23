class AddEnabledToProviderRoutingRules < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_routing_rules, :enabled, :boolean, default: true, null: false unless column_exists?(:provider_routing_rules, :enabled)
  end

  def down
    remove_column :provider_routing_rules, :enabled if column_exists?(:provider_routing_rules, :enabled)
  end
end
