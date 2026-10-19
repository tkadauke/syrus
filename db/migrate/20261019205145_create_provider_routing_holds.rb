class CreateProviderRoutingHolds < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_routing_holds do |t|
      t.references :workflow, null: false
      t.references :step
      t.references :provider_routing_rule
      t.string :status, null: false, default: "active"
      t.string :resumption_mode, null: false
      t.text :reason
      t.json :condition_evidence, null: false
      t.json :matched_scope, null: false
      t.datetime :next_reevaluation_at
      t.datetime :released_at
      t.references :released_by_user
      t.text :release_reason
      t.string :release_kind
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    unless index_exists?(:provider_routing_holds, :workflow_id, name: "idx_provider_routing_holds_active_workflow")
      add_index :provider_routing_holds, :workflow_id,
        unique: true, where: "status = 'active'", name: "idx_provider_routing_holds_active_workflow"
    end
    unless index_exists?(:provider_routing_holds, [ :status, :next_reevaluation_at ], name: "idx_provider_routing_holds_wakeup")
      add_index :provider_routing_holds, [ :status, :next_reevaluation_at ],
        name: "idx_provider_routing_holds_wakeup"
    end
  end
end
