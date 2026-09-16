class AddKnownFlakyFailureDismissalToRepositories < ActiveRecord::Migration[8.1]
  # Opt-in: dismiss a required-grader failure at rung 0 when every one of its
  # failing tests already has a confirmed-flaky history in Test Insights,
  # independent of whether the failure also reproduces on the base branch.
  #
  # Off by default -- same shape as trust_clean_rebase_grade and
  # land_on_inherited_check_failure -- because acting on it silently lets a red
  # required grader land; an operator opts a repository in once its flakiness
  # history is trustworthy.
  def up
    unless column_exists?(:repositories, :known_flaky_failure_dismissal_enabled)
      add_column :repositories, :known_flaky_failure_dismissal_enabled, :boolean, default: false, null: false
    end
    unless column_exists?(:repositories, :known_flaky_failure_min_score)
      add_column :repositories, :known_flaky_failure_min_score, :float
    end
  end

  def down
    remove_column :repositories, :known_flaky_failure_min_score if column_exists?(:repositories, :known_flaky_failure_min_score)
    remove_column :repositories, :known_flaky_failure_dismissal_enabled if column_exists?(:repositories, :known_flaky_failure_dismissal_enabled)
  end
end
