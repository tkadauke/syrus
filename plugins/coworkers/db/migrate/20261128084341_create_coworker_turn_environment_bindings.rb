class CreateCoworkerTurnEnvironmentBindings < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:coworker_turn_environment_bindings)

    create_table :coworker_turn_environment_bindings do |t|
      t.bigint :chat_session_id, null: false
      t.bigint :user_message_id, null: false
      t.bigint :coworker_id, null: false
      t.bigint :environment_activation_id
      t.bigint :environment_revision_id
      t.bigint :coworker_base_release_id, null: false
      t.bigint :runtime_image_id, null: false
      t.boolean :feature_gate_enabled, null: false
      t.string :selection_kind, limit: 32, null: false
      t.string :image_digest, limit: 191, null: false
      t.string :base_digest, limit: 191, null: false
      t.integer :runtime_abi, null: false
      t.string :revocation_state, limit: 32, null: false
      t.timestamps
    end
    add_index :coworker_turn_environment_bindings, :user_message_id,
              unique: true, name: "idx_coworker_turn_env_bindings_message"
    add_index :coworker_turn_environment_bindings, [ :chat_session_id, :created_at ],
              name: "idx_coworker_turn_env_bindings_chat"
    add_index :coworker_turn_environment_bindings, :image_digest,
              name: "idx_coworker_turn_env_bindings_digest"
  end

  def down
    drop_table :coworker_turn_environment_bindings if table_exists?(:coworker_turn_environment_bindings)
  end
end
