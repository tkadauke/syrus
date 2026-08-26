class CreateRefMovementActions < ActiveRecord::Migration[8.1]
  def up
    create_table :ref_movement_actions, if_not_exists: true do |t|
      t.bigint :repository_id, null: false
      t.bigint :job_id
      t.bigint :requested_by_user_id, null: false
      t.string :action_name, null: false, limit: 64
      t.string :source_kind, limit: 32
      t.string :source_ref
      t.bigint :target_repository_id
      t.string :target_kind, limit: 32
      t.string :target_ref
      t.boolean :target_inferred, null: false, default: false
      t.string :mode, limit: 32
      t.json :grade_phases
      t.string :state, null: false, limit: 32, default: "blocked"
      t.string :blocked_reason
      t.bigint :workflow_id

      t.timestamps
    end

    add_index :ref_movement_actions, :repository_id unless index_exists?(:ref_movement_actions, :repository_id)
    add_index :ref_movement_actions, :job_id unless index_exists?(:ref_movement_actions, :job_id)
    add_index :ref_movement_actions, :requested_by_user_id unless index_exists?(:ref_movement_actions, :requested_by_user_id)
    add_index :ref_movement_actions, :target_repository_id unless index_exists?(:ref_movement_actions, :target_repository_id)
    add_index :ref_movement_actions, :workflow_id unless index_exists?(:ref_movement_actions, :workflow_id)
    add_index :ref_movement_actions, :action_name unless index_exists?(:ref_movement_actions, :action_name)
  end

  def down
    drop_table :ref_movement_actions, if_exists: true
  end
end
