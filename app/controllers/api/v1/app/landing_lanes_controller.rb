module Api
  module V1
    module App
      class LandingLanesController < BaseController
        def show
          return render_error("feature_disabled", "Landing lanes are not enabled on this instance.", status: :not_found) unless Feature.landing_lanes_enabled?

          render json: ::App::LandingLanesPayload.call(
            repositories: policy_scope(Repository),
            jobs: policy_scope(Job)
          )
        end
      end
    end
  end
end
