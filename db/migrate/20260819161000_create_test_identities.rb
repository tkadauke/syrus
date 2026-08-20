class CreateTestIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :test_identities, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.string :fingerprint, null: false, limit: 64
      t.string :suite_name, null: false
      t.string :name, null: false
      t.string :file_path
      t.string :last_status, limit: 32
      t.datetime :last_seen_at
      t.datetime :last_failed_at
      t.datetime :last_passed_at
      t.integer :last_duration_ms

      t.timestamps
    end

    add_index :test_identities,
      [ :repository_id, :fingerprint ],
      unique: true,
      name: "idx_test_identities_repo_fingerprint",
      if_not_exists: true

    add_reference :test_cases, :test_identity, foreign_key: false, null: true, if_not_exists: true
    add_index :test_cases, [ :test_identity_id, :created_at ], name: "idx_test_cases_identity_created", if_not_exists: true
    add_index :test_cases, [ :repository_id, :status, :created_at ], name: "idx_test_cases_repo_status_created", if_not_exists: true
  end
end
