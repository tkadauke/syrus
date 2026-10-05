class RemoveMainBranchBreakagePolicyFromAppSettings < ActiveRecord::Migration[8.1]
  # Whether broken main halts unrelated work is repository policy, not
  # deployment policy. RiskProfile already answers it per repository through
  # `Repository#breakage_policy`, so this instance-wide column was a second,
  # louder answer to the same question: a repository on the "standard" posture,
  # whose own policy is to keep work moving, had its landing queue paused
  # anyway because the instance default was "strict".
  def up
    return unless column_exists?(:app_settings, :main_branch_breakage_policy)

    remove_column :app_settings, :main_branch_breakage_policy
  end

  def down
    return if column_exists?(:app_settings, :main_branch_breakage_policy)

    add_column :app_settings, :main_branch_breakage_policy, :string, default: "strict", null: false
  end
end
