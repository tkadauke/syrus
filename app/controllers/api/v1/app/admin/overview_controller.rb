module Api
  module V1
    module App
      module Admin
        class OverviewController < BaseController
          def show
            render json: ::Admin::OverviewPayload.new(params: params).as_json
          end
        end
      end
    end
  end
end
