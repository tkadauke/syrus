class CreateCoworkerEnvironments < ActiveRecord::Migration[8.1]
  def up
    create_table :coworker_environments, if_not_exists: true do |t|
      t.integer :coworker_id, null: false
      t.string :state, null: false, default: "unconfigured"
      t.integer :active_revision_id
      t.integer :candidate_revision_id
      t.integer :active_runtime_image_id
      t.integer :candidate_runtime_image_id
      t.integer :last_audit_event_id
      t.string :last_error_code
      t.timestamps
    end
    add_index :coworker_environments, :coworker_id, unique: true, if_not_exists: true
    add_index :coworker_environments, :state, if_not_exists: true

    create_table :coworker_environment_revisions, if_not_exists: true do |t|
      t.integer :coworker_environment_id, null: false
      t.integer :number, null: false
      t.string :state, null: false, default: "draft"
      t.string :source_digest, limit: 191, null: false
      t.json :source_manifest
      t.string :recipe_digest, limit: 191
      t.integer :runtime_image_build_request_id
      t.integer :runtime_image_id
      t.integer :coworker_base_release_id
      t.integer :runtime_abi
      t.integer :compat_min
      t.integer :compat_max
      t.integer :created_by_user_id
      t.integer :audit_event_id
      t.timestamps
    end
    add_index :coworker_environment_revisions, %i[coworker_environment_id number], unique: true,
              name: "idx_coworker_env_revisions_number", if_not_exists: true
    add_index :coworker_environment_revisions, %i[coworker_environment_id source_digest],
              name: "idx_coworker_env_revisions_source", if_not_exists: true
    add_index :coworker_environment_revisions, :runtime_image_build_request_id,
              name: "idx_coworker_env_revisions_build", if_not_exists: true
    add_index :coworker_environment_revisions, :runtime_image_id,
              name: "idx_coworker_env_revisions_image", if_not_exists: true
  end

  def down
    drop_table :coworker_environment_revisions, if_exists: true
    drop_table :coworker_environments, if_exists: true
  end
end
