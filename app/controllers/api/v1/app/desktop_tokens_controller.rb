module Api
  module V1
    module App
      # The desktop app auto-provisions its menu-bar Bearer token from the
      # signed-in web session so users never paste a token by hand.
      # Returns the existing token when one is set: `api_token` is
      # deterministic-encrypted (recoverable), and rotating here would break
      # the CLI and every other device sharing ~/.syrus/credentials.
      class DesktopTokensController < BaseController
        def create
          if Current.user.api_token.present?
            render json: { api_token: Current.user.api_token, created: false }
          else
            render json: { api_token: Current.user.generate_api_token!, created: true }, status: :created
          end
        end
      end
    end
  end
end
