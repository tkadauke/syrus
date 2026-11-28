# The admin Run list filters by trigger_kind and pages newest-first. With no
# index on trigger_kind, every such request scanned the whole runs table
# (27 s for a bare COUNT in production).
class AddTriggerKindIdIndexToRuns < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_runs_trigger_kind_id".freeze

  def up
    add_index :runs, [ :trigger_kind, :id ], name: INDEX_NAME unless index_exists?(:runs, [ :trigger_kind, :id ], name: INDEX_NAME)
  end

  def down
    remove_index :runs, name: INDEX_NAME if index_exists?(:runs, [ :trigger_kind, :id ], name: INDEX_NAME)
  end
end
