module Api
  module V1
    module Timeline
      # GET /api/v1/timeline/macro
      #   ?from=ISO8601&to=ISO8601 (default: last hour)
      #   &repository_id=&epic_id=&job_id=&hostname=&status=
      class MacroController < BaseController
        def index
          render json: ::Timeline::MacroQuery.call(
            from: params[:from],
            to: params[:to],
            repository_id: params[:repository_id],
            epic_id: params[:epic_id],
            job_id: params[:job_id],
            hostname: params[:hostname],
            status: params[:status],
            job_type: params[:job_type]
          )
        end
      end
    end
  end
end
