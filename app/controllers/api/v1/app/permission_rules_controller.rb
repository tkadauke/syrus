module Api
  module V1
    module App
      class PermissionRulesController < BaseController
        POLICY_ACTIONS = { "allow" => :grant!, "deny" => :deny! }.freeze

        before_action :reject_invocation_context, only: :history

        def index
          render json: dynamic_payload
        end

        def dynamic_payload
          Permissions::RulesPayload.new(Current.user).as_json
        end

        def catalog
          payload = {
            inherited: Permissions::Catalog.descriptors.map { |descriptor| serialize_descriptor(descriptor) },
            profiles: Permissions::PermissionProfiles.all.map(&:to_h)
          }
          fresh_when(etag: [ "permission-rules-catalog", payload ], public: false)
          render json: payload unless performed?
        end

        def preview_profile
          plan = profile_plan
          render json: { preview: serialize_profile_plan(plan), confirmation_digest: profile_digest(plan) }
        rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError => error
          render_error("invalid_permission_profile", error.message, status: :unprocessable_entity)
        end

        def apply_profile
          subject = params.require(:subject_selector_type)
          rules = PermissionRule.transaction do
            plan = profile_plan(lock: true)
            unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation_digest].to_s, profile_digest(plan))
              return render_error("stale_permission_preview", I18n.t("api.permission_rules.stale_preview"), status: :conflict)
            end

            Permissions::Management.new(Current.user).apply_profile!(plan:, actor: Current.user)
          end
          render json: dynamic_payload.merge(profile: params[:profile], subject_selector_type: subject)
        rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError => error
          render_error("invalid_permission_profile", error.message, status: :unprocessable_entity)
        end

        def history
          render json: Permissions::HistoryPayload.new(Current.user, page: params[:page], per_page: params[:per_page]).as_json
        end

        def create
          payload = permission_rule_params.to_h
          management = Permissions::Management.new(Current.user)
          action = POLICY_ACTIONS.fetch(payload.delete("policy"))
          rule = management.public_send(action, payload, actor: Current.user)
          render json: dynamic_payload.merge(rule_id: rule.id, rule: rule_presenter.as_json(rule)), status: :created
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_rule", error.message, status: :unprocessable_entity)
        end

        def update
          rule = Permissions::Management.new(Current.user).replace_rule!(params[:id], permission_rule_params.to_h, actor: Current.user)
          render json: dynamic_payload.merge(rule_id: rule.id, rule: rule_presenter.as_json(rule))
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
          render json: dynamic_payload.merge(rule_id: rule.id, rule: rule_presenter.as_json(rule)), status: :created
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_preset", error.message, status: :unprocessable_entity)
        end

        def bulk
          operations = bulk_operations
          unless ActiveSupport::SecurityUtils.secure_compare(params[:confirmation_digest].to_s, bulk_digest(operations))
            return render_error("stale_permission_preview", I18n.t("api.permission_rules.stale_preview"), status: :conflict)
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
          render json: dynamic_payload.merge(changed_rule_ids: rules.map(&:id))
        rescue Permissions::Catalog::UnknownCapability, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError => error
          render_error("invalid_permission_bulk", error.message, status: :unprocessable_entity)
        end

        def revoke
          rule = Permissions::Management.new(Current.user).revoke_rule!(params[:id], actor: Current.user)
          render json: dynamic_payload.merge(rule_id: rule.id, rule: rule_presenter.as_json(rule))
        end

        private

        def reject_invocation_context
          return unless current_invocation_context

          render_error("forbidden", I18n.t("api.base.invocation_scope_forbidden"), status: :forbidden)
        end

        def permission_rule_params
          params.require(:permission_rule).permit(
            :policy, :role, :subject_selector_type, :subject_selector_id, :subject_repository_id,
            :capability, :operation, :rationale, :dynamic_future_roles,
            subject_role_keys: [], resource_scope: {}, constraints: {}
          )
        end

        def profile_plan(lock: false)
          Permissions::Management.new(Current.user).profile_plan(
            profile_key: params.require(:profile), subject_selector_type: params.require(:subject_selector_type), lock:
          )
        end

        def serialize_profile_plan(plan)
          {
            profile: plan.fetch(:profile).to_h,
            subject_selector_type: plan.fetch(:subject_selector_type),
            revoked: plan.fetch(:revoked_rules).map { |rule| {
              id: rule.id, policy: rule.policy, capability: rule.capability, operation: rule.operation,
              resource_scope: ToolPayloadRedactor.redact(rule.resource_scope),
              resource_scope_label: rule_scope_label(rule)
            } },
            replacements: plan.fetch(:replacements).map do |replacement|
              descriptor = replacement.fetch(:descriptor)
              {
                policy: replacement.fetch(:policy), capability: descriptor.capability,
                operation: descriptor.operation, resource_scope_label: scope_label(descriptor, {})
              }
            end
          }
        end

        def profile_digest(plan)
          revoked = plan.fetch(:revoked_rules).map { |rule| rule.attributes.slice(*PermissionRule::AUDITED_ATTRIBUTES) }
          replacements = plan.fetch(:replacements).map { |replacement|
            descriptor = replacement.fetch(:descriptor)
            { policy: replacement.fetch(:policy), capability: descriptor.capability, operation: descriptor.operation }
          }
          OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base,
            JSON.generate(profile: plan.fetch(:profile).to_h, subject_selector_type: plan.fetch(:subject_selector_type), revoked:, replacements:))
        end

        def permission_preset_params
          params.require(:permission_rule).permit(
            :preset, :role, :subject_selector_type, :subject_selector_id, :subject_repository_id,
            :capability, :operation, :rationale, :dynamic_future_roles,
            subject_role_keys: [], resource_scope: {}, constraints: {}
          )
        end

        def rule_presenter = @rule_presenter ||= Permissions::RulePresenter.new(Current.user)
        def catalog_by_key = @catalog_by_key ||= Permissions::Catalog.descriptors.index_by { |descriptor| [ descriptor.capability, descriptor.operation ] }

        def rule_scope_label(rule)
          descriptor = catalog_by_key[[ rule.capability, rule.operation ]]
          descriptor ? scope_label(descriptor, rule.resource_scope) : rule.resource_scope.to_json
        end

        def serialize_descriptor(descriptor)
          Permissions::Catalog.as_json(descriptor).slice(
            :capability, :operation, :effects, :risk, :defaults, :resource_scope,
            :requestable_roles, :authority_durations, :presets, :presentation
          ).merge(
            owner: { kind: "provider", name: descriptor.capability.split(".").first },
            editable: false, explanation: "role_default"
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

        def serialize_preview(operations)
          management = Permissions::Management.new(Current.user)
          operations.map do |operation|
            if operation.fetch("action") == "revoke"
              rule = management.rules.find(operation.fetch("id"))
              { action: "revoke", policy: rule.policy, subject: rule.subject_selector_type,
                capability: rule.capability, operation: rule.operation,
                resource_scope_label: rule_scope_label(rule) }
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
