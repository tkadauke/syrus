module Api
  module V1
    module App
      class RepositoryRefMovementActionsController < BaseController
        ALLOWED_ACTIONS = %w[promote_development_to_release].freeze

        def create
          repository = find_writable_repository
          return unless repository

          action_name = params[:action_name].to_s
          unless ALLOWED_ACTIONS.include?(action_name)
            render_error("validation_failed", "Unsupported repository ref-movement action", status: :unprocessable_content)
            return
          end

          action = RefMovementAction.dispatch!(repository: repository, actor: Current.user, action: action_name)
          if action.dispatched?
            render json: { message: I18n.t("api.repository_ref_movement_actions.promotion_dispatched"), ref_movement_action_id: action.id }
          else
            render_error("validation_failed", action.blocked_reason, status: :unprocessable_content)
          end
        end
      end
    end
  end
end
