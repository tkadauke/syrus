class CreateRuntimeImageScanEvidences < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_scan_evidences, if_not_exists: true do |t|
      t.references :runtime_image_verification_attempt, null: false, foreign_key: false, index: false
      t.string :image_digest, limit: 71, null: false
      t.string :scanner_name, limit: 100, null: false
      t.string :scanner_version, limit: 100, null: false
      t.string :database_version, limit: 191, null: false
      t.string :sbom_format, limit: 64, null: false
      t.string :sbom_digest, limit: 71, null: false
      t.string :report_digest, limit: 71, null: false
      t.json :finding_summary
      t.json :exemptions
      t.json :decision_evidence
      t.datetime :scanned_at, null: false
      t.timestamps
    end
    add_index :runtime_image_scan_evidences, :runtime_image_verification_attempt_id, unique: true,
              name: "idx_ri_scan_evidence_attempt", if_not_exists: true
    add_index :runtime_image_scan_evidences, :image_digest,
              name: "idx_ri_scan_evidence_digest", if_not_exists: true
  end

  def down
    drop_table :runtime_image_scan_evidences, if_exists: true
  end
end
