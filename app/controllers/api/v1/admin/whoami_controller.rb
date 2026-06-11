module Api
  module V1
    module Admin
      class WhoamiController < BaseController
        def show
          render json: {
            user: {
              id: current_api_user.id,
              email_address: current_api_user.email_address,
              name: current_api_user.name,
              admin: current_api_user.admin?
            }
          }
        end
      end
    end
  end
end
