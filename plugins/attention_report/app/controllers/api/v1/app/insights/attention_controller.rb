module Api
  module V1
    module App
      module Insights
        class AttentionController < BaseController
          def show
            render json: ::AttentionReport::Report.new(user: Current.user, window_days: params[:window_days]).as_json
          end
        end
      end
    end
  end
end
