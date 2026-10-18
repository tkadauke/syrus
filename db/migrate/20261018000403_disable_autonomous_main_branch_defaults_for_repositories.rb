class DisableAutonomousMainBranchDefaultsForRepositories < ActiveRecord::Migration[8.1]
  def change
    change_column_default :repositories, :pr_cost_footer_enabled, from: true, to: false
    change_column_default :repositories, :main_branch_health_enabled, from: true, to: false
    change_column_default :repositories, :main_branch_repair_enabled, from: true, to: false
    change_column_default :repositories, :main_branch_repair_blocks_work, from: true, to: false
  end
end
