module Api
  module V1
    module App
      class LandingLanesController < BaseController
        def show
          return render_error("feature_disabled", t("api.landing_lanes.feature_disabled"), status: :not_found) unless Feature.landing_lanes_enabled?

          render json: ::App::LandingLanesPayload.call(
            repositories: policy_scope(Repository),
            jobs: policy_scope(Job)
          )
        end
      end
    end
  end
end
