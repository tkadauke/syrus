# An urgent Job holds back every non-urgent Job in its repository, which is
# the point of the urgent priority. The gate was a bare existence check
# though, so it had no liveness bound: an urgent Job parked in a blocking
# state held the gate open indefinitely.
#
# That starved a production repository. Two urgent pull requests whose checks
# were failing sat in `approved` -- a blocking state -- with no way to land
# and no way to leave it. Everything non-urgent behind them stopped: an
# initial workflow waited 17 days, a retry waited 10, five jobs sat in
# landing, and a dozen more queued up behind those. Nothing was deadlocked on
# a lock; the gate simply never closed, because existing in an active state
# was enough to hold it and nothing asked whether the urgent Job was going
# anywhere.
#
# So an urgent Job earns the gate only while it is actually progressing:
# either it has runtime work in flight, or it changed state recently enough
# that another move is still plausible. One that has sat still past
# STALLED_AFTER stops blocking others, and takes the gate back the moment it
# moves again. Priority still decides who goes first; it no longer decides
# who goes at all.
class UrgentWorkGate
  # Long enough that an urgent Job between workflows -- approved and waiting
  # for its landing attempt to be picked up -- keeps the gate across the gap,
  # short enough that a parked one is not a day-long outage for its
  # repository.
  STALLED_AFTER = 30.minutes

  # Narrows urgent candidates to the ones still entitled to block others.
  # Takes a loaded collection rather than a relation so callers keep their own
  # filtering (system-kind exclusions, repository scoping) and this only ever
  # removes stalled Jobs from whatever they already decided was relevant.
  def self.progressing(jobs, now: Time.current)
    jobs = Array(jobs)
    return jobs if jobs.empty?

    ids = jobs.map(&:id)
    active_work_job_ids = Workflow
      .where(job_id: ids, state: Workflow::TriggerKind::ACTIVE_STATES)
      .distinct
      .pluck(:job_id)
      .to_set
    last_moved_at = StateTransition
      .where(subject_type: "Job", subject_id: ids)
      .group(:subject_id)
      .maximum(:created_at)
    cutoff = now - STALLED_AFTER

    jobs.select do |job|
      next true if active_work_job_ids.include?(job.id)

      # A Job with no recorded transition yet -- freshly created, still being
      # triaged -- falls back to its own age so it is not called stalled
      # before it has had a chance to move at all.
      moved_at = last_moved_at[job.id] || job.created_at
      moved_at.present? && moved_at > cutoff
    end
  end

  def self.stalled?(job, now: Time.current)
    progressing([ job ], now: now).empty?
  end
end
