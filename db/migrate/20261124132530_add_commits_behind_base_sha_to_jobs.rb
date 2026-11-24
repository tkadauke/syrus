class AddCommitsBehindBaseShaToJobs < ActiveRecord::Migration[8.1]
  def change
    # The base-branch commit commits_behind_base was counted against. GitHub's
    # pull-request base.sha does not follow the base branch, so the count is
    # computed against the live branch tip and this records which tip it was.
    add_column :jobs, :commits_behind_base_sha, :string unless column_exists?(:jobs, :commits_behind_base_sha)
  end
end
