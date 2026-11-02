module Api
  module V1
    module App
      class NotificationPreferencesController < BaseController
        def show
          render json: preferences_payload
        end

        def update
          preferences = notification_preferences_params
          approval_preferences = approval_delivery_preferences_params
          if preferences.empty? && approval_preferences.empty?
            render_error("validation_failed", "Choose at least one notification preference.", status: :unprocessable_content)
            return
          end

          Current.user.update!(
            notification_preferences: Current.user.notification_preferences.merge(preferences),
            approval_delivery_preferences: Current.user.approval_delivery_preferences.merge(approval_preferences)
          )

          render json: preferences_payload.merge(message: "Notification preferences updated.")
        end

        private

        def preferences_payload
          {
            notification_preferences: Current.user.reload.notification_preferences,
            approval_delivery_preferences: Current.user.approval_delivery_preferences
          }
        end

        def notification_preferences_params
          source = params[:notification_preferences].presence || (params.key?(:approval_delivery_preferences) ? ActionController::Parameters.new : params)
          source
            .permit(*User::NOTIFICATION_PREFERENCES_DEFAULTS.keys)
            .to_h
        end

        def approval_delivery_preferences_params
          params.fetch(:approval_delivery_preferences, {}).permit(*User::APPROVAL_DELIVERY_DEFAULTS.keys).to_h
        end
      end
    end
  end
end
