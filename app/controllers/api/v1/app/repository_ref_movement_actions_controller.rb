module Api
  module V1
    module App
      # Repository-scoped manual ref movement. Job-scoped actions continue to
      # use JobRefMovementActionsController because their authorization and
      # source object are tied to a particular Job.
      class RepositoryRefMovementActionsController < BaseController
        ALLOWED_ACTIONS = %w[promote_development_to_release].freeze

        def create
          repository = find_writable_repository
          return unless repository

          action_name = params[:action_name].to_s
          unless ALLOWED_ACTIONS.include?(action_name)
            render_error("validation_failed", I18n.t("api.repository_ref_movement_actions.invalid_action", action: action_name.presence || I18n.t("api.repository_ref_movement_actions.blank_action")), status: :unprocessable_content)
            return
          end

          action = RefMovementAction.dispatch!(
            repository: repository,
            actor: Current.user,
            action: action_name,
            source: params[:source_branch].to_s.strip.presence,
            target: params[:target_branch].to_s.strip.presence
          )

          if action.dispatched?
            render json: {
              message: I18n.t("api.repository_ref_movement_actions.promotion_started"),
              ref_movement_action_id: action.id,
              workflow_id: action.workflow_id
            }
          else
            render_error("validation_failed", action.blocked_reason || I18n.t("api.repository_ref_movement_actions.blocked"), status: :unprocessable_content)
          end
        end
      end
    end
  end
end
