module Admin
  # Computes the "stuck things" watchlist used by the admin
  # overview's tile + the dedicated /admin/stuck list page. One
  # source of truth so the two views can't drift.
  #
  # Returns Items, each with:
  #   :kind      — :stale_heartbeat | :reaper_starved | :nearly_pruned
  #   :severity  — :warn | :alarm
  #   :detail    — short human description
  #   :run       — Run record, when applicable
  #   :workflow  — Workflow record, when applicable
  #   :job       — Job record, always
  #   :age_label — formatted age ("12m", "2d", "3h")
  #
  # Two heartbeat thresholds — see comment on
  # Admin::OverviewController for the rationale.
  class StuckItems
    ADMIN_STUCK_THRESHOLD = 5.minutes

    Item = Data.define(:kind, :severity, :detail, :age_label, :run, :workflow, :job)

    def self.all
      new.all
    end

    def all
      stale_runs + nearly_pruned_workflows
    end

    private

    def stale_runs
      stuck_cutoff  = ADMIN_STUCK_THRESHOLD.ago
      reaper_cutoff = Run::STALE_HEARTBEAT_THRESHOLD.ago

      Run.where(state: "running")
         .where(
           "(last_heartbeat_at IS NOT NULL AND last_heartbeat_at < :t) OR " \
           "(last_heartbeat_at IS NULL AND started_at < :t)",
           t: stuck_cutoff
         )
         .includes(:job, step: :workflow)
         .map do |r|
        last_signal = r.last_heartbeat_at || r.started_at
        past_reaper = last_signal && last_signal < reaper_cutoff

        Item.new(
          kind:      past_reaper ? :reaper_starved : :stale_heartbeat,
          severity:  past_reaper ? :alarm : :warn,
          detail:    detail_for_run(r, last_signal, past_reaper),
          age_label: age_label_for(last_signal),
          run:       r,
          workflow:  r.step&.workflow,
          job:       r.job
        )
      end
    end

    def nearly_pruned_workflows
      cutoff = (WorkflowWorkspacePruneJob::RETAIN_AFTER_FAILURE - 1.day).ago
      Workflow.where(state: "failed")
              .where(cleaned_up_at: nil)
              .where("finished_at < ?", cutoff)
              .includes(:job)
              .map do |wf|
        Item.new(
          kind:      :nearly_pruned,
          severity:  :warn,
          detail:    "Workflow ##{wf.id} (#{wf.trigger_kind}) failed — workspace about to be pruned",
          age_label: age_label_for(wf.finished_at),
          run:       nil,
          workflow:  wf,
          job:       wf.job
        )
      end
    end

    def detail_for_run(run, last_signal, past_reaper)
      base = "Run ##{run.id} silent for #{age_label_for(last_signal)}"
      past_reaper ? "#{base} — past reaper threshold, but still `running`. ReapStaleRunsJob may be starved." : base
    end

    def age_label_for(time)
      return "—" if time.nil?
      seconds = (Time.current - time).to_i
      return "#{seconds}s" if seconds < 60
      mins = seconds / 60
      return "#{mins}m" if mins < 60
      hours = mins / 60
      return "#{hours}h" if hours < 48
      "#{hours / 24}d"
    end
  end
end
