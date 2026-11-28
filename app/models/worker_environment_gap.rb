# A worker that lacks something a repository's setup needs: a system library
# or header a native extension links against, or an executable the prepare
# commands call. The change is fine -- the same prepare passes on a correctly
# provisioned worker -- so the gap belongs to the worker, not to the Job.
#
# Recorded reactively, when a prepare or grader-checkout install fails with
# `worker_environment_missing` (Runs::LifecyclePropagation), and readable as
# a placement constraint: RunQueueResolver treats a gapped worker as unable
# to run that repository's work, so the retry lands on another worker or
# holds with a named blocker instead of failing again on the same machine.
#
# The table is shared with proactive detection on purpose. A worker probe
# that finds a missing tool records the same row with `source: "probe"` (and
# usually no repository, meaning "every repository"), so a gap found by a
# probe and a gap found by a failure end in the same placement state. See
# `record!`.
#
# A gap stops counting when it is cleared, when it expires, or when the worker
# restarted after it was detected (a reprovisioned worker deserves a fresh
# look), and a successful install of the same repository on that worker
# clears it.
class WorkerEnvironmentGap < ApplicationRecord
  SOURCES = %w[failure probe].freeze
  MISSING_KINDS = %w[library header executable].freeze
  TTL = 6.hours
  BLOCKED_REASON = "worker_environment_missing".freeze

  validates :hostname, :missing_kind, :source, :detected_at, :expires_at, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :missing_kind, inclusion: { in: MISSING_KINDS }

  scope :uncleared, -> { where(cleared_at: nil) }
  scope :unexpired, ->(now = Time.current) { where("expires_at > ?", now) }
  # `repository_id` nil is a worker-wide gap (typically probe-detected).
  scope :for_repository, ->(repository_id) { where(repository_id: [ nil, repository_id ].uniq) }

  class << self
    # The one writer, for reactive and proactive detection alike.
    def record!(hostname:, missing_kind:, source:, missing_name: nil, repository_id: nil,
                worker_storage_key: nil, run_id: nil, evidence: {}, now: Time.current)
      return nil if hostname.blank?

      existing = uncleared.unexpired(now).find_by(hostname: hostname, repository_id: repository_id,
                                                  missing_kind: missing_kind.to_s, missing_name: missing_name)
      if existing
        existing.update!(expires_at: now + TTL, run_id: run_id || existing.run_id, evidence: evidence.presence || existing.evidence)
        return existing
      end

      create!(
        hostname: hostname, worker_storage_key: worker_storage_key, repository_id: repository_id,
        missing_kind: missing_kind.to_s, missing_name: missing_name, source: source.to_s, run_id: run_id,
        evidence: evidence.presence, detected_at: now, expires_at: now + TTL
      )
    end

    # Gaps that currently keep `hostname` from running `repository_id`'s work.
    def active_for(hostname:, repository_id:, now: Time.current)
      return none if hostname.blank?

      gaps = uncleared.unexpired(now).where(hostname: hostname).for_repository(repository_id).to_a
      restarted_at = worker_started_at(hostname)
      gaps = gaps.reject { |gap| restarted_at && restarted_at > gap.detected_at } if restarted_at
      gaps
    end

    def blocks?(hostname:, repository_id:, now: Time.current)
      active_for(hostname: hostname, repository_id: repository_id, now: now).any?
    end

    # Every active gap for the repository, keyed by hostname. RunQueueResolver
    # reads this once per decision.
    def active_by_hostname(repository_id:, now: Time.current)
      uncleared.unexpired(now).for_repository(repository_id).to_a
        .group_by(&:hostname)
        .select { |hostname, _gaps| blocks?(hostname: hostname, repository_id: repository_id, now: now) }
    end

    def clear!(hostname:, repository_id:, now: Time.current)
      return 0 if hostname.blank?

      uncleared.where(hostname: hostname, repository_id: repository_id).update_all(cleared_at: now, updated_at: now)
    end

    # The failure path: a Run whose step declared `worker_environment_missing`
    # names the host it failed on through its processes.
    def record_from_run!(run, problem_evidence:)
      evidence = problem_evidence.to_h.stringify_keys
      hostname = failure_hostname(run)
      return nil if hostname.blank?

      record!(
        hostname: hostname,
        worker_storage_key: run.distributed_parallel_run? ? nil : run.workflow&.worker_storage_key,
        repository_id: run.job&.repository_id,
        missing_kind: evidence["missing_kind"].presence_in(MISSING_KINDS) || "library",
        missing_name: evidence["missing_name"],
        source: "failure",
        run_id: run.id,
        evidence: evidence.slice("command", "exit_status", "error_line", "failed_package")
      )
    end

    def failure_hostname(run)
      run.spawned_processes.where.not(hostname: [ nil, "" ]).order(:id).last&.hostname.presence ||
        (run.workflow&.worker_hostname.presence unless run.distributed_parallel_run?)
    end

    private

    def worker_started_at(hostname)
      InstanceVersion.where(role: "worker", hostname: hostname).maximum(:started_at)
    end
  end

  def describe
    [ missing_kind, missing_name ].compact.join(" ")
  end
end
