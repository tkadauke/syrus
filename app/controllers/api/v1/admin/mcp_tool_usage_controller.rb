module Api
  module V1
    module Admin
      class McpToolUsageController < BaseController
        def show
          render json: ::Admin::McpToolUsagePayload.new(params: params).as_json
        end
      end
    end
  end
end
