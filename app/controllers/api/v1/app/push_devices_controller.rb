module Api
  module V1
    module App
      # Registration endpoint for native push clients (the iOS app). The app
      # loads Syrus in a web view, so registration runs with the signed-in web
      # session; bearer-token callers may register too and simply have no
      # session association.
      class PushDevicesController < BaseController
        def create
          device = PushDevice.register!(
            user: Current.user,
            session: current_session_record,
            token: params.require(:token),
            platform: params[:platform].presence || "ios",
            environment: params[:environment].presence || "production",
            bundle_id: params[:bundle_id].presence,
            device_name: params[:device_name].presence&.slice(0, 255),
            app_version: params[:app_version].presence&.slice(0, 255)
          )
          render json: { push_device: device_json(device) }, status: :ok
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", "#{I18n.t('api.push_devices.errors.invalid')} #{e.record.errors.full_messages.to_sentence}".strip, status: :unprocessable_content)
        end

        def destroy
          Current.user.push_devices.find(params[:id]).destroy!
          head :no_content
        end

        def destroy_by_token
          token = params[:token].to_s.strip.downcase
          return render_error("bad_request", I18n.t("api.push_devices.errors.token_required"), status: :bad_request) if token.blank?

          Current.user.push_devices.where(token: token).destroy_all
          head :no_content
        end

        private

        def current_session_record
          Current.session if Current.session.is_a?(::Session)
        end

        def device_json(device)
          {
            id: device.id,
            platform: device.platform,
            environment: device.environment,
            bundle_id: device.bundle_id,
            device_name: device.device_name,
            app_version: device.app_version,
            last_registered_at: device.last_registered_at.iso8601
          }
        end
      end
    end
  end
end
