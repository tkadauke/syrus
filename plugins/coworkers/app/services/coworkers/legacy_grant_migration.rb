module Coworkers
  class LegacyGrantMigration
    Result = Data.define(:migrated, :already_migrated, :already_canonical, :conflicts, :parity_errors, :errors)

    def self.call(...) = new(...).call

    def initialize(scope: Coworkers::Grant.includes(coworker: :owner_user).order(:id), logger: Rails.logger)
      @scope = scope
      @logger = logger
    end

    def call
      migrated = already_migrated = already_canonical = 0
      conflicts = []
      parity_errors = []
      errors = []
      migrated_ids = PermissionRule.where(source: "coworker_grant_migration").pluck(:provenance).filter_map do |provenance|
        Integer(provenance["legacy_coworker_grant_id"], exception: false)
      end.to_set
      active_rules = active_rules_by_coworker_and_capability
      @scope.find_each do |grant|
        if migrated_ids.include?(grant.id)
          already_migrated += 1
          next
        end
        permissions = Coworkers::PermissionRules.new(grant.coworker)
        existing = active_rules.fetch([ grant.coworker_id, grant.capability ], [])
        if existing.any?
          if parity?(grant, existing)
            already_canonical += 1
          else
            conflicts << { grant_id: grant.id, capability: grant.capability, legacy_policy: grant.approval_policy,
                           canonical_rule_ids: existing.map(&:id), canonical_policies: existing.map(&:policy).uniq.sort,
                           reason: "active canonical rules already exist; legacy authority was not allowed to overwrite them" }
          end
          next
        end
        created = permissions.update!(
          capability: grant.capability, approval_policy: grant.approval_policy,
          constraints: grant.constraints, scope: grant.scope, actor: grant.coworker.owner_user,
          provenance: { "legacy_coworker_grant_id" => grant.id,
                        "legacy_approval_policy" => grant.approval_policy, "migration" => self.class.name },
          source: "coworker_grant_migration", preserve_denial: true
        )
        entry = permissions.entries.find { |candidate| candidate[:capability] == grant.capability }
        unless entry && entry[:approval_policy] == grant.approval_policy &&
            entry[:constraints] == grant.constraints.to_h && entry[:scope] == grant.scope
          parity_errors << { grant_id: grant.id, capability: grant.capability, rule_ids: Array(created).map(&:id),
                             reason: "canonical projection did not preserve policy, scope, or constraints" }
        end
        migrated += 1
      rescue StandardError => error
        errors << { grant_id: grant.id, error: error.message }
        @logger.error("[Coworkers::LegacyGrantMigration] grant_id=#{grant.id} error=#{error.class}: #{error.message}")
      end
      Result.new(migrated:, already_migrated:, already_canonical:, conflicts:, parity_errors:, errors:)
    end

    private

    def active_rules_by_coworker_and_capability
      coworker_ids = @scope.reorder(nil).distinct.pluck(:coworker_id)
      return {} if coworker_ids.empty?

      PermissionRule.active.where(subject_selector_type: "agent", subject_selector_id: coworker_ids.map(&:to_s)).to_a
        .group_by { |rule| [ rule.subject_selector_id.to_i, unversioned(rule.capability) ] }
    end

    def parity?(grant, rules)
      entry = Coworkers::PermissionRules.new(grant.coworker, preloaded_rules: rules).entries
        .find { |candidate| candidate[:capability] == grant.capability }
      entry && Coworkers::PermissionRules::POLICY.fetch(entry[:approval_policy]) ==
        Coworkers::PermissionRules::POLICY.fetch(grant.approval_policy) &&
        entry[:constraints].to_h == grant.constraints.to_h && entry[:scope] == grant.scope
    end

    def unversioned(value) = value.to_s.sub(/@v\d+\z/, "")
  end
end
