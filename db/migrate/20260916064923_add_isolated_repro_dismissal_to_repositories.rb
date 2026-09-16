class AddIsolatedReproDismissalToRepositories < ActiveRecord::Migration[8.1]
  # Opt-in: dismiss a required-grader failure at rung 0
  # (Adjudicators::IsolatedReproDismissal) when every one of its failing
  # tests has an agent-recorded, same-SHA, pre-fix "did not reproduce in
  # isolation" record.
  #
  # Off by default -- same shape as known_flaky_failure_dismissal_enabled and
  # trust_clean_rebase_grade -- because acting on it silently lets a red
  # required grader land; an operator opts a repository in deliberately.
  def up
    unless column_exists?(:repositories, :isolated_repro_dismissal_enabled)
      add_column :repositories, :isolated_repro_dismissal_enabled, :boolean, default: false, null: false
    end
  end

  def down
    remove_column :repositories, :isolated_repro_dismissal_enabled if column_exists?(:repositories, :isolated_repro_dismissal_enabled)
  end
end
