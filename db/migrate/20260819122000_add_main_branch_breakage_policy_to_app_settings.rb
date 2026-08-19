class AddMainBranchBreakagePolicyToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :main_branch_breakage_policy, :string, null: false, default: "strict"
  end
end
