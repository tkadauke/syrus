class CloseNoChangeNeededJobs < ActiveRecord::Migration[8.1]
  class MigrationJob < ActiveRecord::Base
    self.table_name = "jobs"
  end

  def up
    now = Time.current

    MigrationJob
      .where(state: "no_change_needed")
      .update_all([
        "state = ?, closure_reason = ?, finished_at = COALESCE(finished_at, ?), updated_at = ?",
        "closed",
        "no_changes",
        now,
        now
      ])
  end

  def down
    # Intentionally irreversible: no_change_needed is a retired semi-terminal
    # representation for the same successful "no changes" outcome.
  end

end
