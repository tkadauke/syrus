module Api
  module V1
    module App
      class PermissionHubPreferencesController < BaseController
        def update
          mode = params.require(:permission_hub_preferences).require(:mode)
          Current.user.update_permission_hub_mode!(mode)
          render json: preferences_payload
        rescue ArgumentError
          render_error("validation_failed", I18n.t("api.permission_hub_preferences.invalid_mode"), status: :unprocessable_content)
        end

        private

        def preferences_payload
          { mode: Current.user.reload.permission_hub_mode }
        end
      end
    end
  end
end
