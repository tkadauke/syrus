module Api
  module V1
    module App
      module Calendar
        class EventsController < BaseController
          before_action :require_calendar_enabled

          def index
            starts_at = parse_bound!(:starts_at)
            ends_at = parse_bound!(:ends_at)
            render json: ::Calendar::EventQuery.call(user: Current.user, starts_at:, ends_at:)
          rescue ::Calendar::EventQuery::InvalidRange => error
            render_error("invalid_calendar_range", error.message, status: :unprocessable_content)
          end

          private

          def require_calendar_enabled
            return if ::Calendar.enabled?
            render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "calendar"), status: :not_found)
          end

          def parse_bound!(name)
            Time.zone.iso8601(params.require(name))
          rescue ArgumentError
            raise ::Calendar::EventQuery::InvalidRange, "#{name} must be an ISO 8601 timestamp"
          end
        end
      end
    end
  end
end
