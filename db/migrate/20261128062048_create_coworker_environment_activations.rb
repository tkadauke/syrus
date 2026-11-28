class CreateCoworkerEnvironmentActivations < ActiveRecord::Migration[8.1]
  def up
    create_table :coworker_environment_activations, if_not_exists: true do |t|
      t.integer :coworker_environment_id, null: false
      t.integer :environment_revision_id, null: false
      t.integer :runtime_image_id, null: false
      t.integer :previous_activation_id
      t.integer :verification_attestation_id, null: false
      t.integer :authority_lease_id
      t.integer :inherited_from_activation_id
      t.string :source_digest, limit: 191, null: false
      t.string :image_digest, limit: 191, null: false
      t.string :authority_kind, null: false
      t.string :actor, null: false
      t.datetime :activated_at, null: false
      t.timestamps
    end
    add_index :coworker_environment_activations, %i[coworker_environment_id activated_at],
              name: "idx_coworker_env_activations_history", if_not_exists: true
    add_index :coworker_environment_activations, %i[coworker_environment_id source_digest],
              name: "idx_coworker_env_activations_source", if_not_exists: true
    add_index :coworker_environment_activations, :environment_revision_id,
              name: "idx_coworker_env_activations_revision", if_not_exists: true
    add_column :coworker_environments, :active_activation_id, :integer unless column_exists?(:coworker_environments, :active_activation_id)
    add_index :coworker_environments, :active_activation_id unless index_exists?(:coworker_environments, :active_activation_id)
  end

  def down
    remove_index :coworker_environments, :active_activation_id if index_exists?(:coworker_environments, :active_activation_id)
    remove_column :coworker_environments, :active_activation_id if column_exists?(:coworker_environments, :active_activation_id)
    drop_table :coworker_environment_activations, if_exists: true
  end
end
