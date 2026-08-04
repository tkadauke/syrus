class RunDiagnosticPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  # Daily sweep of stale RunDiagnostic rows. Each one carries an
  # exception backtrace + git snapshot + env snapshot for an
  # individual failed Run; long-term those are noise. 30-day
  # retention is plenty for triaging an incident a couple days
  # later but doesn't let the table balloon unbounded.
  def perform
    n = RunDiagnostic.prunable.delete_all
    Rails.logger.info("[RunDiagnosticPruneJob] deleted #{n} run_diagnostics") if n > 0
  end
end
