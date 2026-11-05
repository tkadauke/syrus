module Api
  module V1
    module App
      module Admin
        class PermissionFactoryResetsController < BaseController
          INSTANCE_CONFIRMATION = "RESET INSTANCE"
          RETAINED_DATA = %w[audit_history users repositories jobs workflows permission_reset_audits].freeze

          before_action :require_syrus_dev

          def preview
            render json: serialize_preview(reset_service.preview)
          rescue ActiveRecord::RecordNotFound => error
            render_error("scope_not_found", error.message, status: :not_found)
          rescue ArgumentError => error
            render_error("invalid_reset_scope", error.message, status: :unprocessable_content)
          end

          def create
            require_instance_confirmation!
            result = reset_service.confirm!(confirmation_digest: params.require(:confirmation_digest))

            render json: {
              outcome: result.record.outcome,
              changed: result.changed?,
              counts: result.counts,
              audit: {
                id: result.record.id,
                completed_at: result.record.completed_at,
                default_version: result.record.default_version
              }
            }
          rescue ActionController::ParameterMissing, ArgumentError => error
            code = error.message == "permission reset preview is stale" ? "stale_preview" : "invalid_reset_request"
            status = code == "stale_preview" ? :conflict : :unprocessable_content
            render_error(code, error.message, status:)
          rescue ActiveRecord::RecordNotFound => error
            render_error("scope_not_found", error.message, status: :not_found)
          end

          private

          def require_syrus_dev
            return if SyrusDev.enabled?

            render json: { error: "syrus_dev_plugin_disabled" }, status: :not_found
          end

          def reset_service
            @reset_service ||= ::SyrusDev::PermissionFactoryReset.new(
              scope_type: params.require(:scope_type),
              scope_id: params[:scope_id],
              initiated_by: current_user
            )
          end

          def require_instance_confirmation!
            return unless params[:scope_type] == "instance"
            return if ActiveSupport::SecurityUtils.secure_compare(params[:typed_confirmation].to_s, INSTANCE_CONFIRMATION)

            raise ArgumentError, "type #{INSTANCE_CONFIRMATION} to reset the instance"
          end

          def serialize_preview(preview)
            preview.to_h.merge(
              retained_data: RETAINED_DATA,
              instance_confirmation: preview.scope_type == "instance" ? INSTANCE_CONFIRMATION : nil
            )
          end
        end
      end
    end
  end
end
