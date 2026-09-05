module Api
  module V1
    module App
      module Admin
        # Admin-wide agent sessions feed: every agentic Run on the instance,
        # regardless of the admin's own repository memberships. `#artifacts`
        # exists because the admin surface can list sessions on repositories
        # the admin has no membership on, so it can't reuse the
        # repository-ownership-scoped `jobs#run_artifacts` route the way the
        # operator surface does -- same transcript-log JSON shape (feeds the
        # same RunTranscriptLogs component), gated by admin instead.
        class AgentActivityController < BaseController
          def sessions
            filter = ::AgentActivity::Filter.from_params(params, user: Current.user)
            result = ::AgentActivity::SessionsQuery.call(
              scope: :admin,
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

          def artifacts
            run = Run.includes(:job, step: :workflow).find_by(id: params[:run_id])
            unless run
              render_error("not_found", "Run not found.", status: :not_found)
              return
            end

            logs = run.job_logs.order(:sequence).map do |log|
              {
                id: log.id,
                sequence: log.sequence,
                kind: log.kind,
                chunk: log.chunk,
                created_at: log.created_at&.iso8601
              }
            end

            render json: {
              job_id: run.job_id,
              workflow_id: run.step&.workflow_id,
              run_id: run.id,
              base_ref: run.base_sha,
              head_ref: run.head_sha,
              agent_diff: run.agent_diff,
              agent_diff_bytes: run.agent_diff&.bytesize || 0,
              step_agent_diff: run.step_agent_diff,
              logs_count: logs.size,
              logs: logs
            }
          end

          private

          def serialize(run)
            ::AgentActivity::SessionSerializer.call(
              run,
              transcript_path: "/api/v1/app/admin/agent_activity/sessions/#{run.id}/artifacts"
            )
          end
        end
      end
    end
  end
end
