class AddPrChecksFailingNamesToJobs < ActiveRecord::Migration[8.1]
  # The landing gate could see *that* a PR's checks were failing but never
  # *which* ones, so it could not tell "this Job broke something" from "this Job
  # inherited a failure that is already red on main". The base side of that
  # comparison already exists (main_branch_health_checks.ci_failed_checks); this
  # is the PR side.
  #
  # JSON with no DB default: MySQL 8 rejects defaults on JSON columns (see
  # CLAUDE.md). Nullable is the correct resting state anyway -- NULL means "we
  # have not recorded names for this SHA", which is distinct from [] meaning
  # "nothing is failing".
  def up
    add_column :jobs, :pr_checks_failing_names, :json unless column_exists?(:jobs, :pr_checks_failing_names)
  end

  def down
    remove_column :jobs, :pr_checks_failing_names if column_exists?(:jobs, :pr_checks_failing_names)
  end
end
