module Api
  module V1
    module App
      class PlatformIdentitiesController < BaseController
        def index
          render json: ::App::PlatformIdentitiesPayload.call(user: Current.user)
        end

        def destroy
          identity = Current.user.platform_identities.find(params[:id])
          identity.destroy!
          render json: ::App::PlatformIdentitiesPayload.call(
            user: Current.user,
            message: I18n.t("api.platform_identities.unlinked")
          )
        end

        def linking_token
          platform = params[:platform].to_s
          unless ::App::PlatformIdentitiesPayload.supported_platform?(platform)
            return render_error("bad_request", I18n.t("api.platform_identities.unsupported_platform"), status: :bad_request)
          end

          unless platform_configured?(platform)
            return render_error("not_configured", I18n.t("api.platform_identities.not_configured", platform: platform.titleize), status: :unprocessable_entity)
          end

          token = Rails.application.message_verifier(:platform_linking)
            .generate({ "user_id" => Current.user.id, "platform" => platform }, expires_in: 15.minutes)

          render json: {
            token: token,
            instructions: linking_instructions(platform, token)
          }
        end

        private

        def platform_configured?(platform)
          ::App::PlatformIdentitiesPayload.platform_configured?(platform)
        end

        def linking_instructions(platform, token)
          ::App::ExternalPlatforms.fetch(platform).linking_instructions(token)
        end
      end
    end
  end
end
