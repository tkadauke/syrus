class AddWorkerStepDurationMetricIndex < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_steps_worker_duration_metric".freeze
  COLUMNS = [ :state, :finished_at, :kind, :started_at ].freeze

  def up
    return if index_exists?(:steps, COLUMNS, name: INDEX_NAME)

    add_index :steps, COLUMNS, name: INDEX_NAME
  end

  def down
    return unless index_exists?(:steps, COLUMNS, name: INDEX_NAME)

    remove_index :steps, name: INDEX_NAME
  end
end
