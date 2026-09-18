class CreateProviderRoutingRules < ActiveRecord::Migration[8.1]
  def up
    create_table :provider_routing_rules, if_not_exists: true do |t|
      t.string :scope_type, limit: 32, null: false
      t.bigint :scope_id, null: false
      t.string :task_key, null: false
      t.json :candidates

      t.timestamps
    end

    unless index_exists?(:provider_routing_rules, [ :scope_type, :scope_id, :task_key ], name: "idx_provider_routing_rules_scope_task_key_unique")
      add_index :provider_routing_rules, [ :scope_type, :scope_id, :task_key ],
                unique: true,
                name: "idx_provider_routing_rules_scope_task_key_unique"
    end

    execute "UPDATE provider_routing_rules SET candidates = '[]' WHERE candidates IS NULL"
    change_column_null :provider_routing_rules, :candidates, false
  end

  def down
    drop_table :provider_routing_rules, if_exists: true
  end
end
