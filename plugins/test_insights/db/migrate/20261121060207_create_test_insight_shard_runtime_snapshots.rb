class CreateTestInsightShardRuntimeSnapshots < ActiveRecord::Migration[8.1]
  def up
    create_table :test_insight_shard_runtime_snapshots, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: false, index: false
      t.string :grader_key, null: false, limit: 191
      t.bigint :source_snapshot_id, null: false
      t.text :profile, limit: 16_777_215, null: false
      t.timestamps
    end

    unless index_exists?(:test_insight_shard_runtime_snapshots, %i[repository_id grader_key source_snapshot_id], name: "idx_test_insight_shard_runtime_snapshot_key")
      add_index :test_insight_shard_runtime_snapshots, %i[repository_id grader_key source_snapshot_id],
                unique: true, name: "idx_test_insight_shard_runtime_snapshot_key"
    end
    add_index :test_insight_shard_runtime_snapshots, %i[created_at id], name: "idx_shard_runtime_snapshots_retention" unless index_exists?(:test_insight_shard_runtime_snapshots, %i[created_at id], name: "idx_shard_runtime_snapshots_retention")
  end

  def down
    drop_table :test_insight_shard_runtime_snapshots, if_exists: true
  end
end
