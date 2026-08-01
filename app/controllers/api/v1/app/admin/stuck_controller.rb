module Api
  module V1
    module App
      module Admin
        class StuckController < BaseController
          def index
            render json: ::Admin::OverviewPayload.new(params: params).stuck_json
          end
        end
      end
    end
  end
end
