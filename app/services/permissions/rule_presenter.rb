module Permissions
  class RulePresenter
    def initialize(user, descriptors: Catalog.descriptors)
      @user = user
      @descriptors = descriptors.index_by { |descriptor| [ descriptor.capability, descriptor.operation ] }
    end

    def as_json(rule)
      serialized = rule.attributes.slice(*PermissionRule::AUDITED_ATTRIBUTES).merge(
        "id" => rule.id,
        "editable" => rule.policy_layer == "agent" && rule.owner_user_id == user.id,
        "owner" => { "kind" => "user", "id" => rule.owner_user_id,
          "name" => rule.owner_user.name.presence || rule.owner_user.email_address }
      )
      descriptor = descriptors[[ rule.capability, rule.operation ]]
      serialized.merge("resource_scope_label" => descriptor ? scope_label(descriptor, rule.resource_scope) : rule.resource_scope.to_json)
    end

    private

    attr_reader :user, :descriptors

    def scope_label(descriptor, scope)
      result = descriptor.resource_scope.label(scope, context: { user: })
      result.success? ? result.value : scope.to_json
    end
  end
end
