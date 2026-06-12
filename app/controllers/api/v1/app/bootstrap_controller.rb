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
            default_chat_path: default_chat_path,
            flash: {}
          ).as_json
          payload[:whoami] = {
            email: Current.user&.email_address,
            token_suffix: Current.user&.api_token.to_s.last(4)
          }
          render json: payload
        end
      end
    end
  end
end
