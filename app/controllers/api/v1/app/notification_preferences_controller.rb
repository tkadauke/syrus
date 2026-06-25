module Api
  module V1
    module App
      class NotificationPreferencesController < BaseController
        def show
          render json: preferences_payload
        end

        def update
          preferences = notification_preferences_params
          if preferences.empty?
            render_error("validation_failed", "Choose at least one notification preference.", status: :unprocessable_content)
            return
          end

          Current.user.update!(notification_preferences: Current.user.notification_preferences.merge(preferences))

          render json: preferences_payload.merge(message: "Notification preferences updated.")
        end

        private

        def preferences_payload
          {
            notification_preferences: Current.user.reload.notification_preferences
          }
        end

        def notification_preferences_params
          source = params[:notification_preferences].presence || params
          source
            .permit(*User::NOTIFICATION_PREFERENCES_DEFAULTS.keys)
            .to_h
        end
      end
    end
  end
end
