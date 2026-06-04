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
      #   GET /api/v1/admin/runs?trigger_kind=ci_failure&job_id=80
      #   GET /api/v1/admin/runs/:run_id/artifacts
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
          scope = Run.includes(:run_diagnostic, :run_failure_classification, step: :workflow)
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

        # Full per-Run diagnostic payload for admin API clients.
        # The compact list intentionally only carries job_log_count;
        # this endpoint returns the ordered JobLog rows and agent diff
        # when a caller needs to explain a specific Run outcome without
        # dropping to kubectl/Rails runner.
        def artifacts
          run = Run.includes(:job_logs, step: :workflow).find(params[:run_id])
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
            step_id: run.step_id,
            step_kind: run.step&.kind,
            run_id: run.id,
            state: run.state,
            trigger_kind: run.trigger_kind,
            agent_diff: run.agent_diff,
            agent_diff_bytes: run.agent_diff&.bytesize || 0,
            logs_count: logs.size,
            logs: logs
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
            failure_category:  failure_category(run.run_failure_classification),
            failure_classification: serialize_failure_classification(run.run_failure_classification),
            started_at:        run.started_at,
            finished_at:       run.finished_at,
            error_class:       run.run_diagnostic&.error_class,
            error_message:     run.run_diagnostic&.error_message&.[](0, 200)
          }
        end

        def failure_category(classification)
          return unless classification

          {
            "rate_limited" => "provider_rate_limited",
            "timeout" => "agent_timeout",
            "worker_died" => "agent_process_died",
            "provider_auth_or_config" => "provider_auth_or_config",
            "provider_transient" => "provider_transient",
            "git_state_corrupt" => "repo_conflict_or_git_state",
            "git_failure" => "repo_conflict_or_git_state",
            "validation_or_user_error" => "validation_or_user_error",
            "database_lock" => "syrus_internal",
            "mcp_sidecar_failure" => "syrus_internal",
            "application_error" => "syrus_internal"
          }.fetch(classification.classification, "unknown")
        end

        def serialize_failure_classification(classification)
          return unless classification

          {
            id: classification.id,
            classification: classification.classification,
            confidence: classification.confidence&.to_f,
            retryable: classification.retryable,
            reason: classification.reason,
            diagnostic_summary: classification.diagnostic_summary,
            classifier_inputs: classification.classifier_inputs,
            classified_at: classification.classified_at
          }
        end
      end
    end
  end
end
