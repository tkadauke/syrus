module Api
  module V1
    module App
      class UserTimeZonesController < BaseController
        def update
          zone = params.require(:time_zone)
          mode = params[:mode].presence

          if mode
            unless mode.in?(User::TIME_ZONE_MODES)
              render_error("validation_failed", "mode must be automatic or manual", status: :unprocessable_content)
              return
            end

            User.validate_time_zone!(zone)
            Current.user.update!(time_zone: zone, time_zone_mode: mode)
          else
            Current.user.report_browser_time_zone!(zone)
          end

          render json: { time_zone: Current.user.reload.time_zone, mode: Current.user.time_zone_mode }
        rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end
      end
    end
  end
end
