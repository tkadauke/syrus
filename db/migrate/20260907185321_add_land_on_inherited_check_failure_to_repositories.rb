class AddLandOnInheritedCheckFailureToRepositories < ActiveRecord::Migration[8.1]
  # Opt-in: when every failing check on a PR is already failing on its base, land
  # anyway instead of holding for an operator override.
  #
  # Off by default because check-run names are coarse -- one "rspec" check can be
  # red on main for spec A and red on a PR for specs A *and* B, and those are
  # indistinguishable by name. Whether that coarseness matters depends on how a
  # repository names its checks, which is exactly why this is per-repository
  # rather than instance-wide (same shape as trust_clean_rebase_grade).
  def up
    unless column_exists?(:repositories, :land_on_inherited_check_failure)
      add_column :repositories, :land_on_inherited_check_failure, :boolean, default: false, null: false
    end
  end

  def down
    if column_exists?(:repositories, :land_on_inherited_check_failure)
      remove_column :repositories, :land_on_inherited_check_failure
    end
  end
end
