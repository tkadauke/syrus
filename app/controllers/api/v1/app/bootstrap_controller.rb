module Api
  module V1
    module App
      class BootstrapController < BaseController
        allow_unauthenticated_access only: :show

        def show
          authenticated?

          render json: AppApi::BootstrapSerializer.new(
            user: Current.user,
            csrf_token: form_authenticity_token,
            default_chat_path: default_chat_path,
            flash: {}
          ).as_json
        end
      end
    end
  end
end
