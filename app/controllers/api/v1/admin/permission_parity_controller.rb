module Api
  module V1
    module Admin
      class PermissionParityController < BaseController
        def show
          payload = ::Admin::PermissionParityDiagnostics.new(limit: params[:limit]).as_json
          payload = payload.slice(:total, :events) unless truthy?(params[:summary])
          render json: payload
        end

        private

        def truthy?(value) = %w[true 1 yes].include?(value.to_s.downcase)
      end
    end
  end
end
