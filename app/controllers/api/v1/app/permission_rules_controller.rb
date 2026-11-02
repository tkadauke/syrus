module Api
  module V1
    module App
      class PermissionRulesController < BaseController
        POLICY_ACTIONS = { "allow" => :grant!, "deny" => :deny! }.freeze

        def index
          management = Permissions::Management.new(Current.user)
          active_rules = management.rules.to_a
          render json: {
            rules: management.rules(active: false).map { |rule| serialize_rule(rule) },
            inherited: Permissions::Catalog.descriptors.map { |descriptor| serialize_descriptor(descriptor, management:, active_rules:) },
            ownership: { editable_layer: "agent", owner_user_id: Current.user.id }
          }
        end

        def history
          render json: Permissions::HistoryPayload.new(Current.user).as_json
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

        def update
          rule = Permissions::Management.new(Current.user).replace_rule!(params[:id], permission_rule_params.to_h, actor: Current.user)
          render json: { rule: serialize_rule(rule) }
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_rule", error.message, status: :unprocessable_entity)
        end

        def preview_bulk
          operations = bulk_operations
          render json: { preview: serialize_preview(operations), confirmation_digest: bulk_digest(operations) }
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordNotFound, ActionController::ParameterMissing, ArgumentError, KeyError => error
          render_error("invalid_permission_bulk", error.message, status: :unprocessable_entity)
        end

        def apply_preset
          rule = Permissions::Management.new(Current.user).apply_preset!(permission_preset_params.to_h, actor: Current.user)
          render json: { rule: serialize_rule(rule) }, status: :created
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_preset", error.message, status: :unprocessable_entity)
        end

        def bulk
          operations = bulk_operations
          unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation_digest].to_s, bulk_digest(operations))
            return render_error("stale_permission_preview", "Preview these permission changes again before confirming.", status: :conflict)
          end

          management = Permissions::Management.new(Current.user)
          rules = PermissionRule.transaction do
            operations.map do |operation|
              if operation.fetch("action") == "revoke"
                management.revoke_rule!(operation.fetch("id"), actor: Current.user)
              else
                payload = operation.except("action", "id")
                action = POLICY_ACTIONS.fetch(payload.delete("policy"))
                management.public_send(action, payload, actor: Current.user)
              end
            end
          end
          render json: { rules: rules.map { |rule| serialize_rule(rule) } }
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_bulk", error.message, status: :unprocessable_entity)
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

        def permission_preset_params
          params.require(:permission_rule).permit(
            :preset, :role, :subject_selector_type, :subject_selector_id, :subject_repository_id,
            :capability, :operation, :rationale, :dynamic_future_roles,
            subject_role_keys: [], resource_scope: {}, constraints: {}
          )
        end

        def serialize_rule(rule)
          serialized = rule.attributes.slice(*PermissionRule::AUDITED_ATTRIBUTES).merge(
            "id" => rule.id, "editable" => rule.policy_layer == "agent" && rule.owner_user_id == Current.user.id,
            "owner" => { "kind" => "user", "id" => rule.owner_user_id, "name" => rule.owner_user.name.presence || rule.owner_user.email_address }
          )
          descriptor = Permissions::Catalog.find!(capability: rule.capability, operation: rule.operation)
          serialized.merge("resource_scope_label" => scope_label(descriptor, rule.resource_scope))
        rescue Permissions::Catalog::UnknownCapability
          serialized.merge("resource_scope_label" => rule.resource_scope.to_json)
        end

        def serialize_descriptor(descriptor, management:, active_rules:)
          Permissions::Catalog.as_json(descriptor).slice(
            :capability, :operation, :effects, :risk, :defaults, :resource_scope,
            :requestable_roles, :authority_durations, :presets
          ).merge(
            owner: { kind: "provider", name: descriptor.capability.split(".").first },
            editable: false, explanation: "role_default",
            matrix_states: matrix_states(descriptor, management:, active_rules:)
          )
        end

        def bulk_operations
          params.require(:operations).map do |operation|
            raise ArgumentError, "each bulk operation must be an object" unless operation.is_a?(ActionController::Parameters)

            operation.to_unsafe_h.slice(
              "action", "id", "policy", "role", "subject_selector_type", "subject_selector_id",
              "subject_repository_id", "capability", "operation", "rationale", "dynamic_future_roles",
              "subject_role_keys", "resource_scope", "constraints"
            )
          end.tap do |operations|
            raise ArgumentError, "bulk changes must contain between 1 and 100 operations" unless operations.length.between?(1, 100)
            raise ArgumentError, "bulk actions must be grant or revoke" unless operations.all? { |item| %w[grant revoke].include?(item["action"]) }
          end
        end

        def matrix_states(descriptor, management:, active_rules:)
          PermissionRule::SUBJECT_SELECTORS.filter_map do |subject, definition|
            next unless definition[:role]

            [ subject, management.matrix_state(descriptor:, role: definition[:role],
              subject_selector_type: subject, active_rules:) ]
          end.to_h
        end

        def serialize_preview(operations)
          management = Permissions::Management.new(Current.user)
          operations.map do |operation|
            if operation.fetch("action") == "revoke"
              rule = management.rules.find(operation.fetch("id"))
              { action: "revoke", policy: rule.policy, subject: rule.subject_selector_type,
                capability: rule.capability, operation: rule.operation, resource_scope_label: serialize_rule(rule)["resource_scope_label"] }
            else
              descriptor = Permissions::Catalog.find!(capability: operation.fetch("capability"), operation: operation["operation"])
              normalized = descriptor.resource_scope.normalize(operation.fetch("resource_scope", {}), context: { user: Current.user })
              raise ArgumentError, "resource scope could not be normalized" if normalized.fail_closed?
              { action: "grant", policy: operation.fetch("policy"), subject: operation.fetch("subject_selector_type"),
                capability: descriptor.capability, operation: descriptor.operation, resource_scope_label: scope_label(descriptor, normalized.value) }
            end
          end
        end

        def scope_label(descriptor, scope)
          result = descriptor.resource_scope.label(scope, context: { user: Current.user })
          result.success? ? result.value : scope.to_json
        end

        def bulk_digest(operations)
          OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate(operations))
        end
      end
    end
  end
end
