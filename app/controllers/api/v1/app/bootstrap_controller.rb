module Api
  module V1
    module App
      class BootstrapController < BaseController
        allow_unauthenticated_access only: :show

        def show
          authenticated?

          payload = AppApi::BootstrapSerializer.new(
            user: Current.user,
            csrf_token: form_authenticity_token,
            flash: {}
          ).as_json
          render json: payload
        end
      end
    end
  end
end
