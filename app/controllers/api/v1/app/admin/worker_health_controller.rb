module Api
  module V1
    module App
      module Admin
        class WorkerHealthController < BaseController
          def show
            render json: ::Admin::WorkerHealthPayload.new(
              hostname: params[:hostname],
              since: params[:since],
              until_time: params[:until],
              sample_limit_per_host: params.fetch(:sample_limit_per_host, ::Admin::WorkerHealthPayload::SAMPLE_LIMIT_PER_HOST)
            ).as_json
          end
        end
      end
    end
  end
end
