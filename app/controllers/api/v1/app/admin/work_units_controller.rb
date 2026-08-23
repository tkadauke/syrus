module Api
  module V1
    module App
      module Admin
        class WorkUnitsController < BaseController
          def index
            render json: ::Admin::WorkUnitsPayload.new(params: params).as_json
          rescue ArgumentError, TypeError => e
            render_error("bad_request", e.message, status: :bad_request)
          end
        end
      end
    end
  end
end
