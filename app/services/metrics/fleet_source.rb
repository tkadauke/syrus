module Metrics
  # The only place that touches InstanceVersion/SpawnedProcess for the
  # "Fleet" metric group. Ordinary ActiveRecord tables (unlike solid_queue_*,
  # see CLAUDE.md), so this is exercised directly in specs.
  class FleetSource
    # Recently-finished processes still matter to a live fleet snapshot -- a
    # process that finished 30 seconds ago is still evidence of what the
    # fleet was just doing. Matches SpawnedProcess.recent_or_active's own
    # default.
    SPAWNED_PROCESS_WINDOW = 1.hour

    # (role, version) pairs for every pod with a fresh heartbeat right now.
    # Two distinct versions per role during a rollout is the expected,
    # informative case -- see InstanceVersion.
    def instance_version_counts
      InstanceVersion.fresh.group(:role, :version).count
    end

    # (kind, state) pairs, where state is "running" for a process still in
    # flight and its terminal outcome (see SpawnedProcess::OUTCOMES) once it
    # has finished. Windowed rather than all-time, because
    # SpawnedProcessPruneJob deletes finished rows after 7 days and this is a
    # live-fleet snapshot, not a historical count.
    def spawned_process_counts(window: SPAWNED_PROCESS_WINDOW)
      SpawnedProcess.recent_or_active(window)
        .pluck(:kind, :finished_at, :outcome)
        .group_by { |kind, finished_at, outcome| [ kind, finished_at.nil? ? "running" : (outcome.presence || "unknown") ] }
        .transform_values(&:count)
    end
  end
end
