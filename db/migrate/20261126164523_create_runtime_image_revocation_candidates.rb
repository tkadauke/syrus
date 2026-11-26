class CreateRuntimeImageRevocationCandidates < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_revocation_candidates, if_not_exists: true do |t|
      t.references :runtime_image, null: false, foreign_key: false, index: false
      t.references :runtime_image_verification_attempt, null: false, foreign_key: false, index: false
      t.string :trigger_kind, limit: 32, null: false
      t.string :severity, limit: 16, null: false
      t.string :state, limit: 24, null: false, default: "open"
      t.string :reason, limit: 500, null: false
      t.datetime :detected_at, null: false
      t.datetime :resolved_at

      t.timestamps
    end
    add_index :runtime_image_revocation_candidates, %i[runtime_image_id state], name: "idx_ri_revocation_candidate_state" unless index_exists?(:runtime_image_revocation_candidates, %i[runtime_image_id state], name: "idx_ri_revocation_candidate_state")
    add_index :runtime_image_revocation_candidates, :runtime_image_verification_attempt_id, unique: true, name: "idx_ri_revocation_candidate_attempt" unless index_exists?(:runtime_image_revocation_candidates, :runtime_image_verification_attempt_id, name: "idx_ri_revocation_candidate_attempt")
  end

  def down
    drop_table :runtime_image_revocation_candidates, if_exists: true
  end
end
