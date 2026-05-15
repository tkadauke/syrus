module Admin
  # Single-page system overview — "is anything wrong?" answered
  # at a glance. Tile-shaped: each tile reports a metric with a
  # color cue and links into the deeper view that explains it.
  # See docs/plans/complete/admin-diagnostics.md (F).
  #
  # The page polls itself every POLL_INTERVAL_SECONDS via the
  # auto-refresh Stimulus controller (turbo-morph visit, so
  # expanded details + scroll position survive). Polling beats
  # broadcasting here because we want a stable refresh rhythm,
  # not a per-row event storm — see the rationale in the queue
  # inspector commit.
  #
  # Heartbeat thresholds — two-tier on purpose:
  #   ADMIN_STUCK_THRESHOLD     — concerning but not yet dead
  #     (~5 min). Anything past this and still `running` shows
  #     up as :warn in the watchlist.
  #   Run::STALE_HEARTBEAT_THRESHOLD (30 min) — the reaper's cap.
  #     Anything past THIS and still `running` means the reaper
  #     itself isn't running; promotes to :alarm so the operator
  #     can investigate (queue starvation, dead worker, etc.).
  #
  # last_heartbeat_at is bumped by RunJob#log and Steps::Base#log
  # on every transcript chunk written (and on blank chunks too —
  # the chunk doesn't get a JobLog row but the heartbeat still
  # moves). Sources of those log calls: claude's streamed
  # assistant text, git stdout via streaming_git, milestone log
  # statements from step handlers. Heartbeat only goes silent
  # during truly opaque waits (long agent thinking, hung tool
  # calls, deadlocks).
  class OverviewController < BaseController
    POLL_INTERVAL_SECONDS = 30

    def show
      @poll_interval = POLL_INTERVAL_SECONDS

      @active_runs_total      = Run.where(state: "running").count
      @active_runs_by_trigger = Run.where(state: "running").group(:trigger_kind).count

      @queued_runs_total      = Run.where(state: "queued").count

      @workers_total = 0
      @workers_stale = 0
      @workers_unreachable = false
      with_queue_tables do
        @workers_total = SolidQueue::Process.where(kind: "Worker").count
        @workers_stale = SolidQueue::Process.where(kind: "Worker")
                                            .where("last_heartbeat_at < ?", 2.minutes.ago)
                                            .count
      end

      # "Overdue" = haven't fired in 5min for sub-minute schedules,
      # 30min for the daily ones. Coarse heuristic: 10min since the
      # last fire (or never-fired flag). We don't parse cron here —
      # just flag tasks that haven't run recently. Tunable as we
      # learn what's noisy.
      @recurring_overdue = []
      with_queue_tables do
        SolidQueue::RecurringTask.find_each do |task|
          last = SolidQueue::RecurringExecution.where(task_key: task.key)
                                               .order(run_at: :desc).first
          if last.nil?
            @recurring_overdue << { key: task.key, age_seconds: nil, never_run: true }
          else
            age = Time.current - last.run_at
            @recurring_overdue << { key: task.key, age_seconds: age.to_i } if age > 10.minutes
          end
        end
      end

      @recent_failures_24h    = Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).count
      @recent_failures_by_kind = Run.where(state: "failed")
                                    .where("finished_at >= ?", 24.hours.ago)
                                    .group(:trigger_kind).count

      # Per-user GH rate limit signal. Surface anyone < 10% of cap;
      # don't overwhelm the tile with healthy users.
      @gh_low_users = User.where("gh_rate_limit_remaining IS NOT NULL AND gh_rate_limit_limit > 0")
                          .select { |u| u.gh_rate_limit_remaining.to_f / u.gh_rate_limit_limit < 0.10 }

      # Agent session capture rate — succeeded agentic Runs in the
      # last 24h, with vs without a captured session. The path-encoding
      # bug would have shown 0% here (every implement Run completed
      # but no session was captured). This tile is the canary.
      agentic_kinds = Step::AGENTIC_KINDS
      recent_agentic = Run.joins(:step)
                          .where(steps: { kind: agentic_kinds })
                          .where(runs: { state: "succeeded" })
                          .where("runs.finished_at >= ?", 24.hours.ago)
      @capture_total = recent_agentic.count
      @capture_with_session = recent_agentic.left_outer_joins(:claude_session)
                                            .where.not(claude_sessions: { id: nil })
                                            .count
      @capture_rate = @capture_total.zero? ? nil : (@capture_with_session.to_f / @capture_total)

      # Stuck-things watchlist — see Admin::StuckItems for the
      # definition. Inline list below the tile is the at-a-glance
      # view; the dedicated /admin/stuck page (admin#stuck) shows
      # the same items with richer per-item context + drill-down
      # links.
      @stuck = StuckItems.all
    end

    private

    def with_queue_tables
      yield
    rescue ActiveRecord::StatementInvalid,
           ActiveRecord::ConnectionNotEstablished,
           ActiveRecord::ActiveRecordError
      @workers_unreachable = true
    end
  end
end
