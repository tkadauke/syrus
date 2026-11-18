module Api
  module V1
    module App
      module Admin
        class PluginConvergenceController < BaseController
          def show
            render json: PluginDesiredState::Convergence.new.as_json
          end
        end
      end
    end
  end
end
