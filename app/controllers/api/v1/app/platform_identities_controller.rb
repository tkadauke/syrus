module Api
  module V1
    module App
      class PlatformIdentitiesController < BaseController
        def index
          render json: ::App::PlatformIdentitiesPayload.for(Current.user)
        end

        def destroy
          identity = Current.user.platform_identities.find(params[:id])
          identity.destroy!
          render json: ::App::PlatformIdentitiesPayload.for(Current.user).merge(
            message: I18n.t("api.platform_identities.unlinked")
          )
        end

        def linking_token
          platform = params[:platform].to_s
          unless PlatformIdentity.available_platforms.include?(platform)
            return render_error("bad_request", I18n.t("api.platform_identities.unsupported_platform"), status: :bad_request)
          end

          config = PlatformIdentity::PlatformConfig::Base.for(platform)
          unless config.configured?
            return render_error("not_configured", I18n.t("api.platform_identities.not_configured", platform: platform.titleize), status: :unprocessable_entity)
          end

          token = Rails.application.message_verifier(:platform_linking)
            .generate({ "user_id" => Current.user.id, "platform" => platform }, expires_in: 15.minutes)

          render json: {
            token: token,
            instructions: config.instructions(token)
          }
        end
      end
    end
  end
end
