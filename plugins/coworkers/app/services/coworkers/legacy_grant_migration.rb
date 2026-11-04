module Coworkers
  class LegacyGrantMigration
    Result = Data.define(:migrated, :already_migrated, :errors)

    def self.call(...) = new(...).call

    def initialize(scope: Coworkers::Grant.includes(coworker: :owner_user).order(:id), logger: Rails.logger)
      @scope = scope
      @logger = logger
    end

    def call
      migrated = already_migrated = 0
      errors = []
      @scope.find_each do |grant|
        provenance = { "legacy_coworker_grant_id" => grant.id, "migration" => self.class.name }
        migrated_before = PermissionRule.where(source: "coworker_grant_migration").detect do |rule|
          rule.provenance["legacy_coworker_grant_id"].to_i == grant.id
        end
        if migrated_before
          already_migrated += 1
          next
        end
        Coworkers::PermissionRules.new(grant.coworker).update!(
          capability: grant.capability, approval_policy: grant.approval_policy,
          constraints: grant.constraints, scope: grant.scope, actor: grant.coworker.owner_user,
          provenance:, source: "coworker_grant_migration"
        )
        migrated += 1
      rescue StandardError => error
        errors << { grant_id: grant.id, error: error.message }
        @logger.error("[Coworkers::LegacyGrantMigration] grant_id=#{grant.id} error=#{error.class}: #{error.message}")
      end
      Result.new(migrated:, already_migrated:, errors:)
    end
  end
end
