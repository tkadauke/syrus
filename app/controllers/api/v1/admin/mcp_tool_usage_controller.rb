module Api
  module V1
    module Admin
      class McpToolUsageController < BaseController
        def show
          payload = ::Admin::McpToolUsagePayload.new(params: params).as_json
          payload[:filters] = payload.fetch(:filters).compact

          render json: payload
        end
      end
    end
  end
end
