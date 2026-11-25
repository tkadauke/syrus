class CreateRuntimeImageBuildEvidences < ActiveRecord::Migration[8.1]
  def change
    create_table :runtime_image_build_evidences, if_not_exists: true do |t|
      t.bigint :runtime_image_build_request_id, null: false
      t.bigint :runtime_image_build_attempt_id, null: false
      t.bigint :runtime_image_id
      # What the attempt ended as: succeeded, failed, canceled (attempt level).
      t.string :outcome, limit: 24, null: false
      t.string :error_code, limit: 64
      t.string :source_digest, limit: 71, null: false
      t.string :recipe_digest, limit: 71
      t.string :platform, limit: 64
      t.string :image_digest, limit: 71
      t.string :policy_digest, limit: 71
      t.string :builder_version, limit: 191
      t.json :base_images
      t.json :policy_snapshot
      t.json :destinations
      t.json :layer_digests
      t.json :resources
      t.integer :log_bytes, null: false, default: 0
      t.integer :log_dropped_bytes, null: false, default: 0
      # mediumtext on MySQL: the log is bounded by RUNTIME_IMAGE_BUILD_LOG_BYTES.
      t.text :log, limit: 16.megabytes - 1
      t.datetime :finished_at, null: false
      t.timestamps
    end
    unless index_exists?(:runtime_image_build_evidences, :runtime_image_build_attempt_id, name: "idx_ri_build_evidence_attempt")
      add_index :runtime_image_build_evidences, :runtime_image_build_attempt_id, unique: true, name: "idx_ri_build_evidence_attempt"
    end
    unless index_exists?(:runtime_image_build_evidences, :runtime_image_build_request_id, name: "idx_ri_build_evidence_request")
      add_index :runtime_image_build_evidences, :runtime_image_build_request_id, name: "idx_ri_build_evidence_request"
    end
    unless index_exists?(:runtime_image_build_evidences, :runtime_image_id, name: "idx_ri_build_evidence_image")
      add_index :runtime_image_build_evidences, :runtime_image_id, name: "idx_ri_build_evidence_image"
    end
  end
end
