class CreateRuntimeImageVerifications < ActiveRecord::Migration[8.1]
  def up
    add_column :runtime_images, :verification_state, :string, limit: 24, default: "candidate", null: false unless column_exists?(:runtime_images, :verification_state)
    change_column_default :runtime_images, :verification_state, "unverified"
    add_index :runtime_images, :verification_state unless index_exists?(:runtime_images, :verification_state)

    create_table :runtime_image_verification_attempts, if_not_exists: true do |t|
      t.references :runtime_image, null: false, foreign_key: false, index: false
      t.integer :number, null: false
      t.string :image_digest, limit: 71, null: false
      t.string :state, limit: 24, null: false, default: "running"
      t.string :decision, limit: 24
      t.string :failure_class, limit: 64
      t.string :failure_code, limit: 64
      t.string :message, limit: 500
      t.json :policy_snapshot
      t.string :policy_digest, limit: 71, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :runtime_image_verification_attempts, %i[runtime_image_id number], unique: true, name: "idx_ri_verification_attempt_number" unless index_exists?(:runtime_image_verification_attempts, %i[runtime_image_id number], name: "idx_ri_verification_attempt_number")
    add_index :runtime_image_verification_attempts, %i[state started_at], name: "idx_ri_verification_attempt_state" unless index_exists?(:runtime_image_verification_attempts, %i[state started_at], name: "idx_ri_verification_attempt_state")

    create_table :runtime_image_verification_checks, if_not_exists: true do |t|
      t.references :runtime_image_verification_attempt, null: false, foreign_key: false, index: false
      t.integer :position, null: false
      t.string :verifier_key, limit: 100, null: false
      t.boolean :required, null: false, default: true
      t.string :state, limit: 24, null: false, default: "pending"
      t.string :failure_class, limit: 64
      t.string :failure_code, limit: 64
      t.string :message, limit: 500
      t.json :evidence_references
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :runtime_image_verification_checks, %i[runtime_image_verification_attempt_id position], unique: true, name: "idx_ri_verification_check_order" unless index_exists?(:runtime_image_verification_checks, %i[runtime_image_verification_attempt_id position], name: "idx_ri_verification_check_order")
  end

  def down
    drop_table :runtime_image_verification_checks, if_exists: true
    drop_table :runtime_image_verification_attempts, if_exists: true
    remove_index :runtime_images, :verification_state if index_exists?(:runtime_images, :verification_state)
    remove_column :runtime_images, :verification_state if column_exists?(:runtime_images, :verification_state)
  end
end
