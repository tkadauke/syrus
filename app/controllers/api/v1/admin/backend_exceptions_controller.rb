module Api
  module V1
    module Admin
      class BackendExceptionsController < BaseController
        def index
          render json: ::Admin::BackendExceptionEventsPayload.new(params: params).as_json
        rescue ArgumentError => e
          render_error("invalid_backend_exception_search", e.message, status: :unprocessable_content)
        end
      end
    end
  end
end
