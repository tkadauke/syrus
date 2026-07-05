class AddGracePeriodSettingsToRepositories < ActiveRecord::Migration[8.1]
  def up
    add_column :repositories, :fork_pr_grace_period_hours, :integer, default: 24, null: false unless column_exists?(:repositories, :fork_pr_grace_period_hours)
    add_column :repositories, :upstream_pr_grace_period_days, :integer, default: 7, null: false unless column_exists?(:repositories, :upstream_pr_grace_period_days)
  end

  def down
    remove_column :repositories, :upstream_pr_grace_period_days if column_exists?(:repositories, :upstream_pr_grace_period_days)
    remove_column :repositories, :fork_pr_grace_period_hours if column_exists?(:repositories, :fork_pr_grace_period_hours)
  end
end
