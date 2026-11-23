module Api
  module V1
    module App
      # Registration endpoints for the native iOS app. The app calls these from
      # inside its signed-in web view, so cookie session + CSRF apply; bearer
      # API tokens also work for non-browser clients.
      class PushDevicesController < BaseController
        # Upsert by token. A token moves to whichever user registered it last:
        # the physical device can only belong to one signed-in user at a time.
        def create
          device = PushDevice.find_or_initialize_by(platform: platform_param, token: normalized_token)
          device.assign_attributes(
            user: Current.user,
            session: Current.session.is_a?(Session) ? Current.session : nil,
            environment: params[:environment].presence || device.environment || "production",
            bundle_id: params[:bundle_id].presence,
            device_name: params[:device_name].to_s.truncate(120).presence,
            app_version: params[:app_version].to_s.truncate(40).presence,
            last_registered_at: Time.current,
            disabled_at: nil,
            disabled_reason: nil
          )
          if device.save
            render json: { push_device: payload(device) }, status: :ok
          else
            render_error("invalid_push_device", device.errors.full_messages.to_sentence, status: :unprocessable_entity)
          end
        end

        # Idempotent: removing an unknown or foreign token is a 204 so the app
        # can always call it on sign-out without branching.
        def destroy
          Current.user.push_devices.where(platform: platform_param, token: normalized_token).destroy_all
          head :no_content
        end

        private

        def platform_param = params[:platform].presence || "ios"

        def normalized_token = params.require(:token).to_s.strip.downcase

        def payload(device)
          { id: device.id, platform: device.platform, environment: device.environment, last_registered_at: device.last_registered_at.iso8601 }
        end
      end
    end
  end
end
