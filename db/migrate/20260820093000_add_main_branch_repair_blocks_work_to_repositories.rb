class AddMainBranchRepairBlocksWorkToRepositories < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:repositories, :main_branch_repair_blocks_work)

    add_column :repositories, :main_branch_repair_blocks_work, :boolean, null: false, default: true
  end
end
