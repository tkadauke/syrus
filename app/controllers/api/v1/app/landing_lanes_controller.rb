module Api
  module V1
    module App
      class LandingLanesController < BaseController
        def show
          render json: ::App::LandingLanesPayload.call(
            repositories: policy_scope(Repository),
            jobs: policy_scope(Job)
          )
        end
      end
    end
  end
end
