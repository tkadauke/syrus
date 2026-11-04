class ResetCoworkerLegacyAuthority < ActiveRecord::Migration[8.1]
  def up
    # Kept empty because some installations recorded this version when it
    # deleted legacy rows. A new migration performs the retry-safe cutover.
  end

  def down
    return unless table_exists?(:permission_rules)

    PermissionRule.where(source: "coworker_grant_migration", revoked_at: nil).find_each do |rule|
      rule.revoke!(actor: rule.created_by_user)
    end
  end
end
