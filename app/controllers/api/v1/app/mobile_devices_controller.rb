module Api
  module V1
    module App
      # Push-notification device registry for first-party native apps (iOS).
      #
      #   POST   /api/v1/app/mobile_devices            register / refresh a token
      #   DELETE /api/v1/app/mobile_devices/unregister remove a token (sign-out,
      #                                                 push disabled, server switch)
      #   GET    /api/v1/app/mobile_devices            diagnostics: the caller's
      #                                                 devices (masked tokens) and
      #                                                 whether APNs is configured
      #   POST   /api/v1/app/mobile_devices/test_notification
      #                                                 send a test push to the
      #                                                 caller's own device(s)
      #
      # Registration upserts on (platform, token): re-registering moves the token
      # to the current user and session, so a device never receives another
      # user's notifications after account switching. Unregistering only removes
      # tokens the current user owns.
      class MobileDevicesController < BaseController
        def index
          devices = Current.user.mobile_devices.order(:id)
          render json: {
            apns_configured: MobileDevices::PushDelivery.client.configured?,
            mobile_devices: devices.map { |device| serialize_diagnostics(device) }
          }
        end

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

        # Only ever touches the current user's devices; `token` (optional)
        # narrows the push to the calling installation.
        def test_notification
          result = MobileDevices::TestPush.new(user: Current.user, token: params[:token]).call
          unless result.configured
            return render_error("apns_not_configured", I18n.t("mobile_devices.test_push.not_configured"), status: :service_unavailable)
          end
          if result.results.empty?
            return render_error("no_registered_device", I18n.t("mobile_devices.test_push.no_devices"), status: :unprocessable_content)
          end

          render json: {
            delivered: result.delivered,
            target_path: MobileDevices::TestPush::TARGET_PATH,
            results: result.results.map do |r|
              { mobile_device_id: r.device.id, outcome: r.outcome, status: r.status, reason: r.reason }
            end
          }
        end

        private

        def device_attributes
          permitted = params.permit(:platform, :token, :apns_environment, :bundle_id, :device_name, :app_version, :os_version)
          raise ActionController::ParameterMissing, :token if permitted[:token].blank?

          permitted.to_h.symbolize_keys.compact_blank
        end

        # Never exposes the full device token: it is a push credential.
        def serialize_diagnostics(device)
          {
            id: device.id,
            platform: device.platform,
            apns_environment: device.apns_environment,
            bundle_id: device.bundle_id,
            device_name: device.device_name,
            app_version: device.app_version,
            token_suffix: device.token.last(6),
            last_registered_at: device.last_registered_at&.iso8601,
            last_delivered_at: device.last_delivered_at&.iso8601,
            disabled_at: device.disabled_at&.iso8601,
            disabled_reason: device.disabled_reason
          }
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
