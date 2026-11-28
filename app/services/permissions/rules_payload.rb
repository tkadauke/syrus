module Permissions
  class RulesPayload
    def initialize(user)
      @user = user
    end

    # The matrix explains every catalog descriptor for every subject role --
    # over a thousand evaluations. Each one read the settings row (through the
    # enforcement switch) and the owner's leases, so the payload cost one query
    # per cell; both are read once here instead.
    def as_json
      AppSetting.with_current_cache { build }
    end

    private

    def build
      management = Management.new(user)
      leases = management.leases.to_a
      active_rules = management.rules.includes(:owner_user).to_a
      rules_by_subject = active_rules.group_by(&:subject_selector_type)
      evaluator_rules_by_subject = rules_by_subject.transform_values do |rules|
        rules.map(&:to_policy_rule)
      end
      presenter = RulePresenter.new(user, descriptors:)
      {
        rules: active_rules.map { |rule| presenter.as_json(rule) },
        permission_hub_mode: user.permission_hub_mode,
        matrix_states: descriptors.to_h { |descriptor|
          [ descriptor_key(descriptor), matrix_states(descriptor, management:, rules_by_subject:,
            evaluator_rules_by_subject:, leases:) ]
        },
        current_profiles: PermissionRule::SUBJECT_SELECTORS.filter_map { |subject, definition|
          next unless definition[:role]
          [ subject, management.current_profile(subject_selector_type: subject) ]
        }.to_h,
        ownership: { editable_layer: "agent", owner_user_id: user.id }
      }
    end

    attr_reader :user

    def descriptors = @descriptors ||= Catalog.descriptors
    def descriptor_key(descriptor) = [ descriptor.capability, descriptor.operation ].join("|")

    def matrix_states(descriptor, management:, rules_by_subject:, evaluator_rules_by_subject:, leases:)
      PermissionRule::SUBJECT_SELECTORS.filter_map do |subject, definition|
        next unless definition[:role]
        subject_rules = rules_by_subject.fetch(subject, [])
        [ subject, management.matrix_state(descriptor:, role: definition[:role],
          subject_selector_type: subject, active_rules: subject_rules,
          evaluator_rules: evaluator_rules_by_subject.fetch(subject, []), leases:) ]
      end.to_h
    end
  end
end
