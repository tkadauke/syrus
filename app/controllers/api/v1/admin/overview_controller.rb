module Api
  module V1
    module Admin
      # Mirror of Admin::OverviewController + Admin::StuckController.
      # Same data assembly (most of it just reads counts off Run /
      # Workflow / SolidQueue tables); both UI and API render from
      # the same Admin::StuckItems source for the watchlist so the
      # two surfaces can't drift.
      #
      #   GET /api/v1/admin/overview → tile-shaped rollup
      #   GET /api/v1/admin/stuck    → full StuckItems list
      class OverviewController < BaseController
        def show
          payload = {
            active_runs: {
              total:       Run.where(state: "running").count,
              by_trigger:  Run.where(state: "running").group(:trigger_kind).count
            },
            queued_runs: {
              total: Run.where(state: "queued").count
            },
            recent_failures_24h: {
              total:      Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).count,
              by_trigger: Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).group(:trigger_kind).count
            },
            github_rate_limits: low_rate_limit_users,
            agent_session_capture_rate: capture_rate_payload,
            claude_session_capture_rate: capture_rate_payload,
            stuck: ::Admin::StuckItems.all.map { |i| serialize_stuck(i) }
          }

          # Workers tile is best-effort — depends on SolidQueue tables.
          payload[:workers] = workers_payload

          # Recurring jobs health — same dependency.
          payload[:recurring] = recurring_payload

          render json: payload
        end

        def stuck
          render json: { items: ::Admin::StuckItems.all.map { |i| serialize_stuck(i) } }
        end

        private

        def low_rate_limit_users
          User.where("gh_rate_limit_remaining IS NOT NULL AND gh_rate_limit_limit > 0").select do |u|
            u.gh_rate_limit_remaining.to_f / u.gh_rate_limit_limit < 0.10
          end.map do |u|
            {
              email: u.email_address,
              remaining: u.gh_rate_limit_remaining,
              limit: u.gh_rate_limit_limit,
              resource: u.gh_rate_limit_resource
            }
          end
        end

        def capture_rate_payload
          recent = Run.joins(:step)
                      .where(steps: { kind: ::Step::AGENTIC_KINDS })
                      .where(runs: { state: "succeeded" })
                      .where("runs.finished_at >= ?", 24.hours.ago)
          total = recent.count
          captured = recent.left_outer_joins(:claude_session)
                           .where.not(claude_sessions: { id: nil })
                           .count
          {
            total: total,
            captured: captured,
            rate: total.zero? ? nil : (captured.to_f / total).round(3)
          }
        end

        def workers_payload
          total = SolidQueue::Process.where(kind: "Worker").count
          stale = SolidQueue::Process.where(kind: "Worker")
                                     .where("last_heartbeat_at < ?", 2.minutes.ago)
                                     .count
          { total: total, stale: stale }
        rescue ActiveRecord::StatementInvalid,
               ActiveRecord::ConnectionNotEstablished,
               ActiveRecord::ActiveRecordError
          { unreachable: true }
        end

        def recurring_payload
          overdue = []
          ::SolidQueue::RecurringTask.find_each do |task|
            last = ::SolidQueue::RecurringExecution.where(task_key: task.key)
                                                   .order(run_at: :desc).first
            if last.nil?
              # Never fired — overdue by definition. Don't compute
              # age (Float::INFINITY would blow up `.to_i` with a
              # FloatDomainError, taking the whole overview down).
              overdue << { key: task.key, age_seconds: nil, never_run: true }
            else
              age = Time.current - last.run_at
              overdue << { key: task.key, age_seconds: age.to_i } if age > 10.minutes
            end
          end
          { overdue: overdue }
        rescue ActiveRecord::StatementInvalid,
               ActiveRecord::ConnectionNotEstablished,
               ActiveRecord::ActiveRecordError
          { unreachable: true }
        end

        def serialize_stuck(item)
          {
            kind: item.kind.to_s,
            severity: item.severity.to_s,
            detail: item.detail,
            age_label: item.age_label,
            run_id: item.run&.id,
            workflow_id: item.workflow&.id,
            job_id: item.job&.id
          }
        end
      end
    end
  end
end
