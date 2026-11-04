class ResetCoworkerLegacyAuthority < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:coworker_grants)

    result = Coworkers::LegacyGrantMigration.call
    raise ActiveRecord::MigrationError, "coworker grant migration failed: #{result.errors.to_json}" if result.errors.any?
  end

  def down
    return unless table_exists?(:permission_rules)

    PermissionRule.where(source: "coworker_grant_migration", revoked_at: nil).find_each do |rule|
      rule.revoke!(actor: rule.created_by_user)
    end
  end
end
