module Permissions
  class RulesPayload
    def initialize(user)
      @user = user
    end

    def as_json
      management = Management.new(user)
      active_rules = management.rules.includes(:owner_user).to_a
      presenter = RulePresenter.new(user, descriptors:)
      {
        rules: active_rules.map { |rule| presenter.as_json(rule) },
        matrix_states: descriptors.to_h { |descriptor|
          [ descriptor_key(descriptor), matrix_states(descriptor, management:, active_rules:) ]
        },
        current_profiles: PermissionRule::SUBJECT_SELECTORS.filter_map { |subject, definition|
          next unless definition[:role]
          [ subject, management.current_profile(subject_selector_type: subject) ]
        }.to_h,
        ownership: { editable_layer: "agent", owner_user_id: user.id }
      }
    end

    private

    attr_reader :user

    def descriptors = @descriptors ||= Catalog.descriptors
    def descriptor_key(descriptor) = [ descriptor.capability, descriptor.operation ].join("|")

    def matrix_states(descriptor, management:, active_rules:)
      PermissionRule::SUBJECT_SELECTORS.filter_map do |subject, definition|
        next unless definition[:role]
        [ subject, management.matrix_state(descriptor:, role: definition[:role],
          subject_selector_type: subject, active_rules:) ]
      end.to_h
    end
  end
end
