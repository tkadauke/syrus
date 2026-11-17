module Api
  module V1
    module Admin
      class PermissionParityController < BaseController
        def show
          payload = ::Admin::PermissionParityDiagnostics.new(limit: params[:limit]).as_json
          payload = payload.slice(:total, :events) unless truthy?(params[:summary])
          render json: payload
        end
      end
    end
  end
end
