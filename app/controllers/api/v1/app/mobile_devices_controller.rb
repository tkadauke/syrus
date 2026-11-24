module Api
  module V1
    module App
      # Push-notification device registry for first-party native apps (iOS).
      #
      #   POST   /api/v1/app/mobile_devices            register / refresh a token
      #   DELETE /api/v1/app/mobile_devices/unregister remove a token (sign-out,
      #                                                 push disabled, server switch)
      #
      # Registration upserts on (platform, token): re-registering moves the token
      # to the current user and session, so a device never receives another
      # user's notifications after account switching. Unregistering only removes
      # tokens the current user owns.
      class MobileDevicesController < BaseController
        def create
          device = MobileDevice.register!(user: Current.user, session: Current.session, attributes: device_attributes)
          render json: { mobile_device: serialize(device) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def unregister
          token = params.require(:token).to_s.downcase
          Current.user.mobile_devices.where(platform: params.fetch(:platform, "ios"), token: token).destroy_all
          head :no_content
        end

        private

        def device_attributes
          permitted = params.permit(:platform, :token, :apns_environment, :bundle_id, :device_name, :app_version, :os_version)
          raise ActionController::ParameterMissing, :token if permitted[:token].blank?

          permitted.to_h.symbolize_keys.compact_blank
        end

        def serialize(device)
          {
            id: device.id,
            platform: device.platform,
            apns_environment: device.apns_environment,
            bundle_id: device.bundle_id,
            last_registered_at: device.last_registered_at.iso8601
          }
        end
      end
    end
  end
end
