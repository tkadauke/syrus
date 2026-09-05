module Api
  module V1
    module App
      # Operator-scoped agent sessions feed: repositories the current user
      # belongs to, plus Jobs they effectively own (AgentActivity::SessionsQuery).
      class AgentActivityController < BaseController
        def sessions
          filter = ::AgentActivity::Filter.from_params(params, user: Current.user)
          result = ::AgentActivity::SessionsQuery.call(
            scope: :mine,
            user: Current.user,
            filter: filter,
            page: params[:page],
            per: params[:per]
          )

          render json: {
            sessions: result[:rows].map { |run| serialize(run) },
            total: result[:total],
            page: result[:page],
            per: result[:per],
            running_count: result[:running_count],
            filter: filter.to_h,
            filter_schema: ::AgentActivity::Filter.schema
          }
        end

        private

        def serialize(run)
          ::AgentActivity::SessionSerializer.call(
            run,
            transcript_path: "/api/v1/app/jobs/#{run.job_id}/runs/#{run.id}/artifacts"
          )
        end
      end
    end
  end
end
