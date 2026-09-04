class AddRiskProfileToRepositories < ActiveRecord::Migration[8.1]
  # workflow-engine-v3 C0: a project's risk posture readable from one value.
  #
  # The four existing main-branch booleans stay authoritative -- they halt work
  # when main breaks, and quietly changing what they mean is not worth the
  # tidiness. What the profile adds is the tier that was missing:
  # `main_branch_breakage_policy` and the attention posture were instance-wide,
  # so an instance hosting a throwaway repo and a production service had to
  # pick one posture for both.
  #
  # Every row is backfilled with the profile that *matches the columns it
  # already has*, rather than a blanket default, so no repository is described
  # as something it is not. Worth stating plainly: Syrus's shipped defaults
  # (grade main, repair, do not auto-approve, halt unrelated work, strict
  # breakage policy) are the plan's `production` posture. Relaxing a project to
  # `standard` is a deliberate act, not something this migration does.
  def up
    add_column :repositories, :risk_profile, :string unless column_exists?(:repositories, :risk_profile)

    RiskProfile::BUILT_IN.each do |posture|
      execute(<<~SQL.squish)
        UPDATE repositories SET risk_profile = #{connection.quote(posture.key)}
        WHERE risk_profile IS NULL
          AND main_branch_health_enabled = #{quoted_bool(posture.main_branch_health_enabled)}
          AND main_branch_repair_enabled = #{quoted_bool(posture.main_branch_repair_enabled)}
          AND main_branch_repair_auto_approve = #{quoted_bool(posture.main_branch_repair_auto_approve)}
          AND main_branch_repair_blocks_work = #{quoted_bool(posture.main_branch_repair_blocks_work)}
      SQL
    end

    # A repository whose booleans match no profile has drifted; it keeps the
    # closest label and reports itself as overridden.
    execute "UPDATE repositories SET risk_profile = 'standard' WHERE risk_profile IS NULL"

    change_column_null :repositories, :risk_profile, false
    change_column_default :repositories, :risk_profile, from: nil, to: "production"
  end

  def down
    remove_column :repositories, :risk_profile if column_exists?(:repositories, :risk_profile)
  end

  def quoted_bool(value)
    connection.quote(value)
  end
end
