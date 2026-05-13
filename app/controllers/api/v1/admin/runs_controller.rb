module Api
  module V1
    module Admin
      # Compact cross-Job Run lookup. Mirrors the shape of
      # `Api::V1::Admin::JobsController#index` but for the Run
      # domain — useful for the "what just failed across the
      # whole system?" question that would otherwise mean
      # walking each Job's nested dump.
      #
      #   GET /api/v1/admin/runs?state=failed&since=2026-05-04T00:00:00Z
      #   GET /api/v1/admin/runs?trigger_kind=pr_comment&job_id=80
      class RunsController < BaseController
        DEFAULT_PER = 50
        MAX_PER     = 100

        # Filters (all optional, AND-composed):
        #   ?state           one of queued|running|succeeded|failed|cancelled
        #   ?trigger_kind    one of Run::TRIGGER_KINDS
        #   ?job_id          numeric Job id (narrows to one Job's runs)
        #   ?since           ISO8601; bound on Run.finished_at OR
        #                    started_at if not finished. Strict gte.
        #
        # Pagination:
        #   ?page (1-indexed), ?per (default 50, max 100)
        def index
          scope = Run.includes(:run_diagnostic, step: :workflow)
                     .order(Arel.sql("COALESCE(finished_at, started_at, created_at) DESC"))
          scope = scope.where(state: params[:state])               if params[:state].present?
          scope = scope.where(trigger_kind: params[:trigger_kind]) if params[:trigger_kind].present?
          scope = scope.where(job_id: params[:job_id])             if params[:job_id].present?
          scope = scope.where("COALESCE(finished_at, started_at, created_at) >= ?", parse_since) if params[:since].present?

          per   = (params[:per].presence || DEFAULT_PER).to_i.clamp(1, MAX_PER)
          page  = [ params[:page].to_i, 1 ].max
          total = scope.count
          rows  = scope.offset((page - 1) * per).limit(per).to_a

          render json: {
            count: rows.size,
            total: total,
            page:  page,
            per:   per,
            runs:  rows.map { |r| serialize_compact(r) }
          }
        end

        private

        def parse_since
          Time.iso8601(params[:since])
        rescue ArgumentError, TypeError
          # Garbage-in: ignore the filter rather than 400. Mirrors
          # how the other admin filters tolerate bad values.
          1.year.ago
        end

        # Compact row. Keep it lean — callers drill into
        # /api/v1/admin/runs/:id/transcript or
        # /api/v1/admin/jobs/:job_id for full state.
        def serialize_compact(run)
          {
            id:                run.id,
            state:             run.state,
            trigger_kind:      run.trigger_kind,
            job_id:            run.job_id,
            workflow_id:       run.step&.workflow_id,
            workflow_state:    run.step&.workflow&.state,
            step_id:           run.step_id,
            step_kind:         run.step&.kind,
            agent_outcome:     run.agent_outcome,
            started_at:        run.started_at,
            finished_at:       run.finished_at,
            error_class:       run.run_diagnostic&.error_class,
            error_message:     run.run_diagnostic&.error_message&.[](0, 200)
          }
        end
      end
    end
  end
end
