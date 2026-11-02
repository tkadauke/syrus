module Api
  module V1
    module App
      class PermissionRulesController < BaseController
        POLICY_ACTIONS = { "allow" => :grant!, "deny" => :deny! }.freeze

        def index
          management = Permissions::Management.new(Current.user)
          render json: {
            rules: management.rules(active: false).map { |rule| serialize_rule(rule) },
            inherited: Permissions::Catalog.descriptors.map { |descriptor| serialize_descriptor(descriptor) },
            ownership: { editable_layer: "agent", owner_user_id: Current.user.id }
          }
        end

        def create
          payload = permission_rule_params.to_h
          management = Permissions::Management.new(Current.user)
          action = POLICY_ACTIONS.fetch(payload.delete("policy"))
          rule = management.public_send(action, payload, actor: Current.user)
          render json: { rule: serialize_rule(rule) }, status: :created
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_rule", error.message, status: :unprocessable_entity)
        end

        def revoke
          rule = Permissions::Management.new(Current.user).revoke_rule!(params[:id], actor: Current.user)
          render json: { rule: serialize_rule(rule) }
        end

        private

        def permission_rule_params
          params.require(:permission_rule).permit(
            :policy, :role, :subject_selector_type, :subject_selector_id, :subject_repository_id,
            :capability, :operation, :rationale, :dynamic_future_roles,
            subject_role_keys: [], resource_scope: {}, constraints: {}
          )
        end

        def serialize_rule(rule)
          rule.attributes.slice(*PermissionRule::AUDITED_ATTRIBUTES).merge(
            "id" => rule.id, "editable" => rule.policy_layer == "agent" && rule.owner_user_id == Current.user.id,
            "owner" => { "kind" => "user", "id" => rule.owner_user_id, "name" => rule.owner_user.name.presence || rule.owner_user.email_address }
          )
        end

        def serialize_descriptor(descriptor)
          Permissions::Catalog.as_json(descriptor).slice(:capability, :operation, :effects, :risk, :defaults, :resource_scope).merge(
            owner: { kind: "provider", name: descriptor.capability.split(".").first },
            editable: false, explanation: "role_default"
          )
        end
      end
    end
  end
end
