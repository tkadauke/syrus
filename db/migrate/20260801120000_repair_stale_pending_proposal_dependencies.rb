class RepairStalePendingProposalDependencies < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Repairing stale pending proposal dependencies" do
      result = Maintenance::RepairStaleParsedPendingDependenciesOnNonIssueJobs.call
      say "removed #{result.removed_count} stale dependencies; restarted #{result.restarted_job_ids.size} jobs", true
    end
  end

  def down
    # One-time data repair; there is no safe inverse.
  end
end
