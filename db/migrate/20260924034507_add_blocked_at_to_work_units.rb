class AddBlockedAtToWorkUnits < ActiveRecord::Migration[8.1]
  # When a WorkUnit blocks, "blocked since" used to be read off
  # `updated_at`. Re-checks (main-branch health re-polls every 5 minutes,
  # admission control on every dispatcher tick) touch the row without
  # changing the reason, so the age reset on every tick: a block that had
  # been in force for thirteen hours reported five minutes, and every
  # staleness heuristic keyed on it -- the pill's 30-minute escalation, the
  # stuck-item age -- could never fire.
  #
  # `blocked_at` is stamped only when the unit enters a block (or changes
  # reason) and cleared when it leaves, so it measures the episode.
  def up
    add_column :work_units, :blocked_at, :datetime unless column_exists?(:work_units, :blocked_at)

    # Existing blocked rows: updated_at is the best available approximation
    # and is never worse than the NULL fallback.
    execute "UPDATE work_units SET blocked_at = updated_at WHERE blocked_reason IS NOT NULL AND blocked_at IS NULL"
  end

  def down
    remove_column :work_units, :blocked_at if column_exists?(:work_units, :blocked_at)
  end
end
