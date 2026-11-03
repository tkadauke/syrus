module Api
  module V1
    module App
      # One draft/preview/apply contract for every permission-authoring surface.
      class PermissionRuleDraftsController < BaseController
        before_action :reject_invocation_context

        def options
          descriptor = Permissions::Catalog.find!(capability: params.require(:capability), operation: params[:operation])
          render json: { options: Permissions::RuleDraftOptions.new(descriptor, user: Current.user).as_json }
        rescue Permissions::Catalog::UnknownCapability, ActionController::ParameterMissing => error
          render_error("invalid_permission_draft", error.message, status: :unprocessable_entity)
        end

        # Derives a draft from an authorization request item, then previews it.
        def from_request
          request = ChatPendingAction.where(user: Current.user).find(params.require(:request_id))
          item = request.authorization_items.find(params.require(:item_id))
          draft = Permissions::RuleDraft.from_request_item(user: Current.user, request:, item:,
            duration: params.require(:duration), policy: params[:policy].presence || "allow")
          render_preview(draft)
        rescue ActionController::ParameterMissing, ArgumentError => error
          render_error("invalid_permission_draft", error.message, status: :unprocessable_entity)
        end

        def preview
          render_preview(build_draft)
        end

        def apply
          rule = build_draft.apply!(digest: params[:digest], actor: Current.user)
          render json: { authority: serialize_authority(rule) }, status: :created
        rescue Permissions::RuleDraft::Stale => error
          render_error("stale_permission_preview", error.message, status: :conflict)
        rescue Permissions::RuleDraft::Invalid, ActiveRecord::RecordInvalid, ArgumentError => error
          render_error("invalid_permission_draft", error.message, status: :unprocessable_entity)
        end

        private

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
          render json: { preview: preview.to_h }, status: (preview.valid? ? :ok : :unprocessable_entity)
        end

        def serialize_authority(record)
          { kind: record.class.name, id: record.id, capability: record.capability, operation: record.operation,
            resource_scope: ToolPayloadRedactor.redact(record.resource_scope) }
        end
      end
    end
  end
end
