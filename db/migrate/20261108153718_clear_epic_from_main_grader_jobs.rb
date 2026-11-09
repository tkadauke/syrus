class ClearEpicFromMainGraderJobs < ActiveRecord::Migration[8.1]
  # main_grader Jobs are repository-wide infrastructure anchors and must never
  # belong to an Epic. A stale-intake classifier loop used to attach some to
  # an Epic by mistake. Clear only the Epic membership metadata; Workflow,
  # Run, health, and closure history are left untouched. Idempotent.
  def up
    execute <<~SQL.squish
      UPDATE jobs
      SET epic_id = NULL, epic_title = NULL
      WHERE kind = 'main_grader' AND epic_id IS NOT NULL
    SQL
  end

  def down
    # Irreversible by design: the cleared memberships were invalid.
  end
end
