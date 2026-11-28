module Invariants
  # A failed Job must not silently block other work.
  #
  # When a stack parent or a declared dependency fails, everything behind it
  # waits: the Jobs that depend on it, its stacked children, and through them
  # the rest of an Epic chain. The failure itself is visible on the failed Job,
  # but the blast radius is not -- a failed stack parent once held a whole Epic
  # for days with nobody noticing. Each failed Job that has waiting dependents
  # once it has been failed for `min_age` is one violation, listing what it
  # blocks and how its last failure was classified, so the operator can tell
  # "retry it" from "fix it" from "cut the dependency".
  class FailedBlockers < Base
    DEFAULTS = { min_age: 1.hour }.freeze
    WAITING_STATES = %w[backlog needs_triage triaging blocked_by_epic queued implemented approved].freeze

    def violations
      edges = dependency_edges + stack_edges
      return [] if edges.empty?

      by_blocker = edges.group_by(&:first)
      blockers = Job.where(id: by_blocker.keys).index_by(&:id)
      dependents = Job.where(id: edges.map { |edge| edge[1] }).index_by(&:id)
      failed_at = Workflow.where(job_id: by_blocker.keys, state: "failed").group(:job_id).maximum(:finished_at)

      by_blocker.filter_map do |blocker_id, blocker_edges|
        job = blockers[blocker_id]
        next unless job

        since = failed_at[job.id] || job.updated_at
        next unless older_than?(since, options.fetch(:min_age))

        blocked = blocker_edges.uniq { |edge| edge[1] }.filter_map do |_, dependent_id, relation|
          dependent = dependents[dependent_id]
          dependent && job_ref(dependent).merge(relation: relation, epic_id: dependent.epic_id)
        end
        next if blocked.empty?

        classification = latest_classification(job)
        violation(
          severity: :critical,
          subject_type: "Job",
          subject_id: job.id,
          since: since,
          message_params: { job: job.slug, count: blocked.size, blocked: blocked.map { |ref| ref[:slug] }.first(5).join(", "),
                            hours: hours_since(since) },
          affected_ids: { job_ids: [ job.id, *blocked.map { |ref| ref[:id] } ] },
          details: {
            job: job_ref(job),
            epic_id: job.epic_id,
            failed_since: iso(since),
            failed_hours: hours_since(since),
            blocked_jobs: blocked,
            blocked_epic_ids: blocked.filter_map { |ref| ref[:epic_id] }.uniq,
            failure: classification
          }
        )
      end
    end

    private

    # [failed_job_id, dependent_job_id, relation]
    def dependency_edges
      relation = JobDependency.joins("INNER JOIN jobs blockers ON blockers.id = job_dependencies.depends_on_job_id")
                              .joins("INNER JOIN jobs dependents ON dependents.id = job_dependencies.job_id")
                              .where(blockers: { state: "failed" }, dependents: { state: WAITING_STATES })
      relation = relation.where("blockers.id IN (:ids) OR dependents.id IN (:ids)", ids: scope.job_ids) unless scope.all?
      relation.pluck("blockers.id", "dependents.id").map { |blocker, dependent| [ blocker, dependent, "dependency" ] }
    end

    def stack_edges
      relation = Job.joins("INNER JOIN jobs parents ON parents.id = jobs.parent_job_id")
                    .where(parents: { state: "failed" }, state: WAITING_STATES)
      relation = relation.where("parents.id IN (:ids) OR jobs.id IN (:ids)", ids: scope.job_ids) unless scope.all?
      relation.pluck("parents.id", "jobs.id").map { |parent, child| [ parent, child, "stack_child" ] }
    end

    def latest_classification(job)
      run = Run.where(job_id: job.id, state: "failed")
               .select(:id, :finished_at, :step_id)
               .reorder(finished_at: :desc, id: :desc)
               .first
      return nil unless run

      record = RunFailureClassification.find_by(run_id: run.id)
      {
        run_id: run.id,
        step_kind: Step.where(id: run.step_id).pick(:kind),
        finished_at: iso(run.finished_at),
        classification: record&.classification,
        retryable: record&.retryable,
        reason: record&.reason.to_s.squish.truncate(300).presence
      }
    end
  end
end
