class CreateRuntimeImagePolicyEvidences < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_image_policy_evidences, if_not_exists: true do |t|
      t.references :runtime_image_verification_attempt, null: false, foreign_key: false,
                   index: { unique: true, name: "idx_ri_policy_evidence_attempt" }
      t.string :image_digest, limit: 71, null: false
      t.json :safe_summary, null: false
      t.string :report_digest, limit: 71, null: false
      t.datetime :scanned_at, null: false

      t.timestamps
    end
  end
end
