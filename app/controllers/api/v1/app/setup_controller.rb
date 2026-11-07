module Api
  module V1
    module App
      class SetupController < BaseController
        def show
          render json: AppApi::SetupStatus.new(Current.user).as_json
        end
      end
    end
  end
end
