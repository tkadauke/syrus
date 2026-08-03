module Api
  module V1
    module Admin
      class PluginsController < BaseController
        def index
          render json: ::Admin::PluginsPayload.new.as_json
        end
      end
    end
  end
end
