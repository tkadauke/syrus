module Invariants
  # A dependency that can no longer succeed must not silently hold its
  # dependents.
  #
  # FailedBlockers covers a failed blocker. The quieter case is a blocker that
  # finished without succeeding: a Job whose PR was closed unmerged (the
  # dependency's satisfaction policy calls it terminal-unsuccessful), or an
  # Epic every one of whose Jobs is closed while the Epic itself never became
  # done. Nothing will ever satisfy such a dependency, and the dependent reads
  # as calmly waiting -- queued behind a dependency, or blocked_by_epic --
  # forever. Each such blocker with waiting dependents, once it has been
  # finished for `min_age`, is one violation, so the operator can cut the
  # dependency, reopen the work, or close the dependents.
  #
  # Detection only: this does not change what satisfies a dependency.
  class AbandonedBlockers < Base
    DEFAULTS = { min_age: 1.hour }.freeze
    WAITING_STATES = FailedBlockers::WAITING_STATES

    def violations
      job_blocker_violations + epic_blocker_violations
    end

    private

    def waiting_dependencies
      relation = JobDependency.joins("INNER JOIN jobs dependents ON dependents.id = job_dependencies.job_id")
                              .where(dependents: { state: WAITING_STATES })
      relation = relation.where(job_id: scope.job_ids) unless scope.all?
      relation.includes(:job, :depends_on_job, :depends_on_epic)
    end

    def job_blocker_violations
      dependencies = waiting_dependencies.where.not(depends_on_job_id: nil)
                                         .joins("INNER JOIN jobs blockers ON blockers.id = job_dependencies.depends_on_job_id")
                                         .where(blockers: { state: "closed" })
                                         .select(&:dependency_terminal_unsuccessful_for_execution?)
      dependencies.group_by(&:depends_on_job).filter_map do |blocker, edges|
        since = blocker.updated_at
        next unless older_than?(since, options.fetch(:min_age))

        build(subject: blocker, kind: "job", since: since, edges: edges,
              details: { closure_reason: blocker.closure_reason })
      end
    end

    def epic_blocker_violations
      dependencies = waiting_dependencies.where.not(depends_on_epic_id: nil).to_a
      dependencies.group_by(&:depends_on_epic).filter_map do |epic, edges|
        next if epic.nil? || epic.done?

        jobs = Job.where(epic_id: epic.id).select(:id, :state, :updated_at).to_a
        next if jobs.empty? || jobs.any? { |job| job.state != "closed" }

        since = jobs.map(&:updated_at).max
        next unless older_than?(since, options.fetch(:min_age))

        build(subject: epic, kind: "epic", since: since, edges: edges,
              details: { epic_state: epic.state, closed_job_ids: jobs.map(&:id) })
      end
    end

    def build(subject:, kind:, since:, edges:, details:)
      blocked = edges.map(&:job).compact.uniq(&:id)
      return nil if blocked.empty?

      label = kind == "job" ? subject.slug : "Epic ##{subject.id} #{subject.title}"
      violation(
        severity: :critical,
        subject_type: subject.class.name,
        subject_id: subject.id,
        since: since,
        message_params: {
          blocker: label,
          count: blocked.size,
          blocked: blocked.map(&:slug).first(5).join(", "),
          hours: hours_since(since)
        },
        affected_ids: { job_ids: [ (subject.id if kind == "job"), *blocked.map(&:id) ].compact },
        details: details.merge(
          blocker_kind: kind,
          finished_since: iso(since),
          blocked_jobs: blocked.map { |job| job_ref(job).merge(epic_id: job.epic_id) },
          blocked_epic_ids: blocked.filter_map(&:epic_id).uniq
        )
      )
    end
  end
end
