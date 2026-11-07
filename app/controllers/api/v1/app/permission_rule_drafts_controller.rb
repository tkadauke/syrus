module Api
  module V1
    module App
      # One draft/preview/apply contract for every permission-authoring surface.
      class PermissionRuleDraftsController < BaseController
        before_action :reject_invocation_context

        def options
          descriptor = Permissions::Catalog.find!(capability: params.require(:capability), operation: params[:operation])
          payload = Permissions::RuleDraftOptions.new(descriptor, user: Current.user).as_json
          fresh_when(etag: [ "permission-rule-draft-options", Current.user.id, payload ], public: false)
          render json: { options: payload } unless performed?
        rescue Permissions::Catalog::UnknownCapability, ActionController::ParameterMissing => error
          render_error("invalid_permission_draft", error.message, status: :unprocessable_entity)
        end

        # Derives a draft from an authorization request item, then previews it.
        def from_request
          request = ChatPendingAction.where(user: Current.user).find(params.require(:request_id))
          item = request.authorization_items.find(params.require(:item_id))
          draft = Permissions::RuleDraft.from_request_item(user: Current.user, request:, item:,
            duration: params.require(:duration), policy: params[:policy].presence || "allow",
            constraints: prefix_constraints(item))
          render_preview(draft)
        rescue ActionController::ParameterMissing, ArgumentError => error
          render_error("invalid_permission_draft", error.message, status: :unprocessable_entity)
        end

        def preview
          render_preview(build_draft)
        end

        # An operator previewing a widened prefix needs the digest for *that*
        # draft, so the preview has to be built with the prefix they typed.
        def prefix_constraints(item)
          prefix = params[:prefix].presence
          return nil unless prefix

          field = Permissions::SmartDecision.new(request: item.chat_pending_action, item:, user: Current.user).prefix_field
          raise ArgumentError, I18n.t("api.permission_requests.smart_decision.prefix_unavailable") unless field

          { field => prefix.to_s.strip }
        end

        def apply
          rule = apply_draft!
          render json: { authority: serialize_authority(rule) }, status: :created
        rescue ActiveRecord::RecordNotFound
          render_error("not_found", I18n.t("api.permission_rule_drafts.errors.unknown_rule"), status: :not_found)
        rescue Permissions::RuleDraft::Stale => error
          render_error("stale_permission_preview", error.message, status: :conflict)
        rescue Permissions::RuleDraft::Invalid, ActiveRecord::RecordInvalid, ArgumentError => error
          render_error("invalid_permission_draft", error.message, status: :unprocessable_entity)
        end

        private

        # Editing replaces a rule: the new authority is applied against the
        # previewed state, then the old rule is revoked in the same transaction
        # so ownership, audit history and immediate revocation stay intact.
        def apply_draft!
          PermissionRule.transaction do
            rule = build_draft.apply!(digest: params[:digest], actor: Current.user)
            if params[:replace_rule_id].present?
              Permissions::Management.new(Current.user).revoke_rule!(params[:replace_rule_id], actor: Current.user)
            end
            rule
          end
        end

        def reject_invocation_context
          return unless current_invocation_context

          render_error("forbidden", I18n.t("api.base.invocation_scope_forbidden"), status: :forbidden)
        end

        def build_draft
          Permissions::RuleDraft.new(user: Current.user, attributes: draft_params, request_scope: requested_scope)
        end

        # Optional request context lets the preview flag a scope edited beyond what was asked.
        def requested_scope
          return if params[:request_id].blank?

          request = ChatPendingAction.where(user: Current.user).find(params[:request_id])
          request.authorization_items.find(params.require(:item_id)).resource_scope
        end

        def draft_params
          params.require(:draft).permit(
            :policy, :duration, :subject_selector_type, :subject_selector_id, :subject_type,
            :subject_repository_id, :role, :capability, :operation, :chat_session_id, :job_id, :rationale,
            resource_scope: {}, constraints: {}
          )
        end

        def render_preview(draft)
          preview = draft.preview
          return render json: { preview: preview.to_h } if preview.valid?

          # ApiError surfaces error.issues, which the editor renders inline.
          render json: { preview: preview.to_h, error: { code: "invalid_permission_draft",
            message: preview.errors.pluck(:message).join("; "), issues: preview.errors } }, status: :unprocessable_entity
        end

        def serialize_authority(record)
          { kind: record.class.name, id: record.id, capability: record.capability, operation: record.operation,
            resource_scope: ToolPayloadRedactor.redact(record.resource_scope) }
        end
      end
    end
  end
end
