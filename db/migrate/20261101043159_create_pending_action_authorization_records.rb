class CreatePendingActionAuthorizationRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :pending_action_items, if_not_exists: true do |t|
      t.references :chat_pending_action, null: false, foreign_key: false
      t.string :kind, null: false
      t.string :state, null: false, default: "pending"
      t.string :capability, null: false
      t.integer :capability_version, null: false, default: 1
      t.string :operation
      t.integer :operation_version
      t.string :resource_type, null: false
      t.json :resource_scope, null: false
      t.json :normalized_arguments, null: false
      t.string :invocation_fingerprint
      t.json :effects, null: false
      t.string :risk
      t.string :classifier_confidence
      t.json :policy_chain, null: false
      t.json :decisive_rule, null: false
      t.text :purpose
      t.json :requested_durations, null: false
      t.string :selected_duration
      t.references :decision_principal, polymorphic: true, null: true
      t.references :resulting_authority, polymorphic: true, null: true
      t.datetime :decided_at
      t.text :decision_reason
      t.datetime :non_actionable_at
      t.text :non_actionable_reason
      t.timestamps
    end
    add_index :pending_action_items, [ :chat_pending_action_id, :state ], name: "idx_pending_action_items_request_state" unless index_exists?(:pending_action_items, name: "idx_pending_action_items_request_state")
    add_index :pending_action_items, :invocation_fingerprint unless index_exists?(:pending_action_items, :invocation_fingerprint)

    create_table :pending_action_item_prerequisites, if_not_exists: true do |t|
      t.references :pending_action_item, null: false, foreign_key: false, index: false
      t.references :prerequisite, null: false, foreign_key: false, index: false
      t.datetime :created_at, null: false
    end
    add_index :pending_action_item_prerequisites, [ :pending_action_item_id, :prerequisite_id ], unique: true, name: "idx_pending_action_item_prerequisites_unique" unless index_exists?(:pending_action_item_prerequisites, name: "idx_pending_action_item_prerequisites_unique")
    add_index :pending_action_item_prerequisites, :prerequisite_id unless index_exists?(:pending_action_item_prerequisites, :prerequisite_id)

    create_table :pending_action_transitions, if_not_exists: true do |t|
      t.references :chat_pending_action, null: false, foreign_key: false
      t.references :pending_action_item, null: true, foreign_key: false
      t.integer :sequence, null: false
      t.string :event_type, null: false
      t.string :from_state
      t.string :to_state, null: false
      t.references :actor, polymorphic: true, null: true
      t.json :metadata, null: false
      t.datetime :created_at, null: false
    end
    add_index :pending_action_transitions, [ :chat_pending_action_id, :sequence ], unique: true, name: "idx_pending_action_transitions_sequence" unless index_exists?(:pending_action_transitions, name: "idx_pending_action_transitions_sequence")
    add_index :pending_action_transitions, [ :pending_action_item_id, :created_at ], name: "idx_pending_action_item_transitions" unless index_exists?(:pending_action_transitions, name: "idx_pending_action_item_transitions")
  end

  def down
    drop_table :pending_action_transitions if table_exists?(:pending_action_transitions)
    drop_table :pending_action_item_prerequisites if table_exists?(:pending_action_item_prerequisites)
    drop_table :pending_action_items if table_exists?(:pending_action_items)
  end
end
