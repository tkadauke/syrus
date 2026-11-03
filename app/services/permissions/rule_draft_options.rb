module Permissions
  # Describes everything a permission-authoring surface may offer for one
  # descriptor, derived only from the descriptor and the owner's active rules.
  class RuleDraftOptions
    def initialize(descriptor, user:)
      @descriptor = descriptor
      @user = user
    end

    def as_json(*)
      {
        capability: descriptor.capability, operation: descriptor.operation,
        policies: RuleDraft::POLICIES, risk: descriptor.risk.to_s,
        subject_types: subject_types,
        resource_scope: descriptor.resource_scope.to_h,
        constraint_fields: descriptor.constraint_fields.transform_values(&:to_s),
        presets: descriptor.presets,
        authority_durations: authority_durations,
        maximum_autonomy: descriptor.maximum_autonomy.to_s,
        maximum_duration_seconds: descriptor.maximum_duration&.to_i,
        permanent_allowed: authority_durations.include?("permanent"),
        ceilings: ceilings
      }
    end

    private

    attr_reader :descriptor, :user

    # Durations a draft may request: the descriptor's own durations, bounded by
    # its maximum autonomy. Invocation authority is decided on the request itself.
    def authority_durations
      @authority_durations ||= RuleDraft::DURATIONS.select do |duration|
        descriptor.authority_durations.map(&:to_s).include?(duration) &&
          AuthorityGrant::Base::AUTONOMY_RANK.fetch(duration.to_sym) <= AuthorityGrant::Base::AUTONOMY_RANK.fetch(descriptor.maximum_autonomy)
      end
    end

    def subject_types
      PermissionRule::SUBJECT_SELECTORS.filter_map do |type, definition|
        next if RuleDraft::EXCLUDED_SELECTORS.include?(type)

        roles = eligible_roles(definition)
        next if roles.empty?

        { type:, requires_id: definition[:id], requires_repository: definition[:repository],
          roles:, exact_agent: type == "agent" }
      end
    end

    def eligible_roles(definition)
      return descriptor.requestable_roles if definition[:id] && !definition[:role_from_id]
      return descriptor.requestable_roles if definition[:role_from_id]

      Array(definition[:role]).select { |role| descriptor.requestable_roles.include?(role) }
    end

    # Non-delegable rules cap what lower layers can grant; surfaced so a surface
    # can explain why an option is unavailable.
    def ceilings
      Management.new(user).rules.for_capability(descriptor.capability, descriptor.operation)
        .where(delegable: false).map do |rule|
          { id: rule.id, layer: rule.policy_layer, policy: rule.policy,
            subject_selector_type: rule.subject_selector_type }
        end
    end
  end
end
