module Api
  module V1
    module App
      module Admin
        class SettingsController < BaseController
          def show
            render json: settings_payload
          end

          def update
            setting = AppSetting.current

            if setting.update(settings_params)
              render json: settings_payload.merge(message: I18n.t("api.admin_settings.updated"))
            else
              render_error("validation_failed", setting.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          def clear_secret
            label = AppSetting.clearable_secrets[params[:secret].to_s]
            return render_error("unknown_secret", I18n.t("api.admin_settings.unknown_secret"), status: :unprocessable_content) unless label

            AppSetting.current.clear_secret!(params[:secret])
            render json: settings_payload.merge(message: I18n.t("api.admin_settings.secret_cleared", label: label))
          end

          private

          def settings_payload
            setting = AppSetting.current
            {
              settings: {
                signups_open: setting.signups_open,
                clearable_secrets: AppSetting.clearable_secrets.map do |key, label|
                  {
                    key: key,
                    label: label,
                    set: setting.public_send(key).present?
                  }
                end
              }
            }
          end

          def settings_params
            permitted_settings = [ :signups_open ] + AppSetting.clearable_secrets.keys.map(&:to_sym)

            params
              .expect(app_setting: permitted_settings)
              .to_h
              .reject { |key, value| key != "signups_open" && value.blank? }
          end
        end
      end
    end
  end
end
