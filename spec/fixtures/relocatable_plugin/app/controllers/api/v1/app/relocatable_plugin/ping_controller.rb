module Api
  module V1
    module App
      module RelocatablePlugin
        class PingController < Syrus::Host::AppController
          def show
            render json: { plugin: "relocatable_plugin", location: "external" }
          end
        end
      end
    end
  end
end
