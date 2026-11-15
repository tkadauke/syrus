class MigrateCoworkerGrantsToPermissionRules < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:coworker_grants) && table_exists?(:permission_rules)

    say "coworker grant migration: #{Coworkers::LegacyGrantMigration.call.to_h.to_json}"
  end

  def down
    return unless table_exists?(:permission_rules)

    count = 0
    PermissionRule.where(source: "coworker_grant_migration", revoked_at: nil).find_each do |rule|
      rule.revoke!(actor: rule.created_by_user)
      count += 1
    end
    say "coworker grant rollback: revoked #{count} migrated rules; any preserved legacy rows remain available"
  end
end
