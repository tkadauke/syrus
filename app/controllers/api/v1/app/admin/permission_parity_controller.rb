module Api
  module V1
    module App
      module Admin
        class PermissionParityController < BaseController
          def show
            render json: ::Admin::PermissionParityDiagnostics.new(limit: params[:limit]).as_json
          end
        end
      end
    end
  end
end
