module Coworkers
  class PermissionCutoverReport
    ROLES = [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].freeze
    LEGACY_POLICIES = { "auto" => :allow, "confirm" => :ask, "queue" => :ask }.freeze

    def initialize(coworker:, registrations: Permissions::CapabilityRegistryValidator.for_application.registrations,
      findings: Permissions::CapabilityRegistryValidator.for_application.findings)
      @coworker = coworker
      @registrations = registrations
      @findings = findings
    end

    def as_json(*)
      {
        ready: descriptor_gaps.empty? && migration_errors.empty?,
        legacy_grants: legacy_grants,
        recommended_defaults: recommended_defaults,
        lost_authority: lost_authority,
        requestable_replacements: requestable_replacements,
        descriptor_gaps: descriptor_gaps,
        migration_errors: migration_errors
      }
    end

    private

    attr_reader :coworker, :registrations, :findings

    def legacy_grants
      @legacy_grants ||= coworker.grants.order(:capability).map do |grant|
        {
          capability: grant.capability,
          approval_policy: grant.approval_policy,
          effective_policy: LEGACY_POLICIES.fetch(grant.approval_policy),
          scope: grant.scope,
          constraints: grant.constraints
        }
      end
    end

    def recommendations
      @recommendations ||= relevant_registrations.filter_map do |registration|
        descriptor = registration.descriptor
        next unless registration.explicit_descriptor && descriptor
        next unless (descriptor.requestable_roles & ROLES).any?

        {
          capability: descriptor.capability,
          operation: descriptor.operation,
          tools: [ registration.tool_name ],
          roles: ROLES.index_with { |role| descriptor.defaults[role]&.to_s }.compact,
          requestable_roles: descriptor.requestable_roles & ROLES
        }
      end.group_by { |item| [ item[:capability], item[:operation], item[:roles] ] }.map do |_, items|
        items.first.merge(tools: items.flat_map { |item| item[:tools] }.uniq.sort)
      end.sort_by { |item| [ item[:capability], item[:operation] ] }
    end

    def recommended_defaults = recommendations

    def lost_authority
      legacy_grants.flat_map do |legacy|
        legacy_recommendations(legacy[:capability]).flat_map do |recommendation|
          recommendation[:roles].filter_map do |role, policy|
            next unless policy_rank(policy) < policy_rank(legacy[:effective_policy])

            {
              legacy_capability: legacy[:capability],
              capability: recommendation[:capability],
              operation: recommendation[:operation],
              role: role,
              before: legacy[:effective_policy],
              after: policy
            }
          end
        end
      end
    end

    def requestable_replacements
      recommendations.filter_map do |recommendation|
        roles = recommendation[:roles].select { |_, policy| policy == "ask" }.keys
        next if roles.empty?

        recommendation.slice(:capability, :operation, :tools).merge(roles: roles)
      end
    end

    def descriptor_gaps
      @descriptor_gaps ||= legacy_grants.filter_map do |grant|
        matching = registrations_for(grant[:capability])
        reasons = []
        reasons << "no registered tools" if matching.empty?
        reasons << "missing explicit descriptors" if matching.any? { |registration| !registration.explicit_descriptor || registration.descriptor.nil? }
        explicit = matching.select { |registration| registration.explicit_descriptor && registration.descriptor }
        reasons << "missing coworker role defaults" if explicit.empty? || explicit.any? { |registration| (ROLES - registration.descriptor.requestable_roles).any? }
        next if reasons.empty?

        { legacy_capability: grant[:capability], tools: matching.map(&:tool_name).uniq.sort, reasons: reasons.uniq }
      end
    end

    def migration_errors
      @migration_errors ||= begin
        errors = findings.filter_map do |finding|
          affected = finding.registrations & relevant_registrations
          next if affected.empty?

          { code: finding.code.to_s, message: finding.message, tools: affected.map(&:tool_name).uniq.sort }
        end
        conflicting_recommendations.each { |conflict| errors << conflict }
        errors
      end
    end

    def conflicting_recommendations
      recommendations.group_by { |item| item[:operation] }.filter_map do |operation, items|
        next if items.map { |item| item[:roles] }.uniq.one?

        { code: "conflicting_coworker_defaults", message: "#{operation} declares conflicting coworker defaults", tools: items.flat_map { |item| item[:tools] }.uniq.sort }
      end
    end

    def relevant_registrations
      @relevant_registrations ||= legacy_grants.flat_map { |grant| registrations_for(grant[:capability]) }.uniq
    end

    def registrations_for(legacy_capability)
      registrations.select do |registration|
        descriptor = registration.descriptor
        descriptor && unversioned(descriptor.capability) == legacy_capability
      end
    end

    def legacy_recommendations(capability)
      recommendations.select { |recommendation| unversioned(recommendation[:capability]) == capability }
    end

    def unversioned(identifier) = identifier.to_s.sub(/@v\d+\z/, "")
    def policy_rank(policy) = { "deny" => 0, "ask" => 1, "allow" => 2 }.fetch(policy.to_s)
  end
end
