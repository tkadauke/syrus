class CreatePermissionRulesAndAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :permission_rules, if_not_exists: true do |t|
      t.references :owner_user, null: false, foreign_key: { to_table: :users }
      t.string :subject_selector_type, null: false
      t.string :subject_selector_id
      t.json :subject_role_keys, null: false
      t.references :subject_repository, null: true, foreign_key: { to_table: :repositories }
      t.string :capability, null: false
      t.string :operation
      t.string :resource_type, null: false
      t.json :resource_scope, null: false
      t.string :policy, null: false
      t.json :constraints, null: false
      t.string :policy_layer, null: false
      t.string :source, null: false
      t.json :provenance, null: false
      t.boolean :dynamic_future_roles, null: false, default: false
      t.boolean :delegable, null: false, default: true
      t.text :rationale
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.references :updated_by_user, null: false, foreign_key: { to_table: :users }
      t.datetime :revoked_at
      t.references :revoked_by_user, null: true, foreign_key: { to_table: :users }
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :permission_rules,
      [ :owner_user_id, :subject_selector_type, :subject_selector_id, :revoked_at ],
      name: "idx_permission_rules_current_subject" unless index_exists?(:permission_rules,
        [ :owner_user_id, :subject_selector_type, :subject_selector_id, :revoked_at ],
        name: "idx_permission_rules_current_subject")
    add_index :permission_rules, [ :capability, :operation, :revoked_at ],
      name: "idx_permission_rules_current_capability" unless index_exists?(:permission_rules,
        [ :capability, :operation, :revoked_at ], name: "idx_permission_rules_current_capability")
    add_index :permission_rules, [ :subject_repository_id, :revoked_at ],
      name: "idx_permission_rules_current_repository" unless index_exists?(:permission_rules,
        [ :subject_repository_id, :revoked_at ], name: "idx_permission_rules_current_repository")

    create_table :permission_rule_audit_events, if_not_exists: true do |t|
      t.references :permission_rule, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.string :event_type, null: false
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.json :snapshot, null: false
      t.json :changed_fields, null: false
      t.datetime :created_at, null: false
    end

    add_index :permission_rule_audit_events, [ :permission_rule_id, :sequence ], unique: true,
      name: "idx_permission_rule_audits_sequence" unless index_exists?(:permission_rule_audit_events,
        [ :permission_rule_id, :sequence ], name: "idx_permission_rule_audits_sequence")
    add_index :permission_rule_audit_events, [ :actor_user_id, :created_at ],
      name: "idx_permission_rule_audits_actor" unless index_exists?(:permission_rule_audit_events,
        [ :actor_user_id, :created_at ], name: "idx_permission_rule_audits_actor")
  end

  def down
    drop_table :permission_rule_audit_events, if_exists: true
    drop_table :permission_rules, if_exists: true
  end
end
