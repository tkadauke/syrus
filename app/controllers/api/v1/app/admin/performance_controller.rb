module Api
  module V1
    module App
      module Admin
        class PerformanceController < BaseController
          def show
            render json: PerformanceLogging.suppress { ::Admin::PerformancePayload.new(params: params).as_json }
          end
        end
      end
    end
  end
end
