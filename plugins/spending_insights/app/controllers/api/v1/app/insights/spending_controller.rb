module Api
  module V1
    module App
      module Insights
        class SpendingController < BaseController
          def show
            filter_params = request.query_parameters.sort.to_h
            cache_key = [ "spending-insights", Current.user.id, filter_params, Time.zone.today, Time.current.to_i / 5.minutes ]
            fresh_when(etag: cache_key, public: false)
            return if performed?

            payload = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
              ::SpendingInsights::Payload.new(user: Current.user, params: params).as_json
            end
            render json: payload
          end
        end
      end
    end
  end
end
