# Fences Run execution: incremented every time a worker claims the Run, so an
# executor that stalled and was replaced (its Run requeued and claimed again)
# sees the counter move at its next liveness checkpoint and stops before any
# further side effect.
class AddExecutionAttemptToRuns < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:runs, :execution_attempt)

    add_column :runs, :execution_attempt, :integer, default: 0, null: false
  end
end
