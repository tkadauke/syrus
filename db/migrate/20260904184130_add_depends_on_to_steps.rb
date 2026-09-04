class AddDependsOnToSteps < ActiveRecord::Migration[8.1]
  # workflow-engine-v3 A5: real graph edges.
  #
  # `next_step_id` is a linked list, so "find next" is a walk and fan-in needs
  # a sentinel (WAITING_FOR_BATCH) plus a per-kind rule
  # (waits_for_terminal_step_kind). `depends_on_ids` makes the same thing a
  # ready-set query: a Step is runnable when every id it names is terminal.
  #
  # Additive on purpose. next_step_id stays and stays authoritative for
  # ordering; edges are populated alongside it, and a Step with no edges falls
  # back to the linked-list predecessor. Nothing has to be backfilled for
  # in-flight work to keep running.
  def up
    return if column_exists?(:steps, :depends_on_ids)

    add_column :steps, :depends_on_ids, :json
    execute "UPDATE steps SET depends_on_ids = '[]' WHERE depends_on_ids IS NULL"
    change_column_null :steps, :depends_on_ids, false
  end

  def down
    remove_column :steps, :depends_on_ids if column_exists?(:steps, :depends_on_ids)
  end
end
