module Api
  module V1
    module App
      module Insights
        class SpendingController < BaseController
          def show
            render json: ::App::SpendingPayload.new(
              user: Current.user,
              params: params
            ).as_json
          end
        end
      end
    end
  end
end
