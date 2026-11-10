class BackfillRunDiffsFromRuns < ActiveRecord::Migration[8.1]
  def up
    RunDiffs::Backfill.new.call
  end

  def down
    # The copy is non-destructive; the legacy columns stay until the next
    # migration drops them.
  end
end
