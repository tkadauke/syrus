class RefreshInProgressEpicsWithClosedChildren < ActiveRecord::Migration[8.1]
  def up
    Epic.where(state: "in_progress")
        .where.not(
          id: Job.where.not(state: "closed")
                 .where.not(epic_id: nil)
                 .select(:epic_id)
        )
        .find_each(&:refresh_auto_state!)
  end

  def down
    # One-time auto-state refresh; there is no safe inverse.
  end
end
