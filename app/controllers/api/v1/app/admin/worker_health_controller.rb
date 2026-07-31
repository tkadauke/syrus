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
              sample_limit_per_host: params.fetch(:sample_limit_per_host, ::Admin::WorkerHealthPayload::SAMPLE_LIMIT_PER_HOST),
              minute_bucket_window_minutes: params.fetch(
                :minute_bucket_window_minutes,
                ::Admin::WorkerHealthPayload::DEFAULT_MINUTE_BUCKET_WINDOW / 1.minute
              )
            ).as_json
          end
        end
      end
    end
  end
end
