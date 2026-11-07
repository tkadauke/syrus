module Api
  module V1
    module App
      module Insights
        class AttentionController < BaseController
          def show
            window_days = (Integer(params[:window_days].presence || 7, exception: false) || 7).clamp(1, 90)
            cache_key = [ "attention-report", Current.user.id, window_days, Time.current.to_i / 5.minutes ]
            fresh_when(etag: cache_key, public: false)
            return if performed?

            payload = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
              ::AttentionReport::Report.new(user: Current.user, window_days: window_days).as_json
            end
            render json: payload
          end
        end
      end
    end
  end
end
