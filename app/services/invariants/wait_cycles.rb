module Invariants
  # Blocked work must not wait on itself.
  #
  # A blocked WorkUnit with a named reason reads as explained -- every other
  # invariant treats "blocked on a reason" as held, not stranded. But when the
  # reason names another workflow ("blocking_workflow_id": an epic-wide
  # workflow, a running member, a patient rebase's publisher) and that
  # workflow's unit is in turn blocked on this one, nothing can ever move: an
  # epic-wide stack rebase once waited patiently on a member's CI repair that
  # was itself held back by the rebase. Each cycle of such waits, held for
  # `grace`, is one violation.
  class WaitCycles < Base
    DEFAULTS = { grace: 15.minutes }.freeze
    BLOCKING_KEY = "blocking_workflow_id".freeze

    def violations
      edges = wait_edges
      return [] if edges.empty?

      cycles(edges).filter_map do |cycle_ids|
        units = WorkUnit.where(id: cycle_ids).includes(:workflow).index_by(&:id)
        ordered = cycle_ids.map { |id| units[id] }.compact
        next if ordered.size != cycle_ids.size

        since = ordered.filter_map { |unit| unit.blocked_at || unit.updated_at }.max
        next unless older_than?(since, options.fetch(:grace))

        job_ids = ordered.filter_map { |unit| unit.workflow&.job_id }.uniq
        violation(
          severity: :critical,
          subject_type: "WorkUnit",
          subject_id: ordered.first.id,
          discriminator: "cycle:#{cycle_ids.sort.join("-")}",
          since: since,
          message_params: {
            units: ordered.map(&:slug).join(" -> "),
            reasons: ordered.map(&:blocked_reason).join(", ")
          },
          affected_ids: { work_unit_ids: cycle_ids, workflow_ids: ordered.filter_map(&:workflow_id), job_ids: job_ids },
          details: {
            cycle: ordered.map do |unit|
              {
                work_unit_id: unit.id,
                kind: unit.kind,
                blocked_reason: unit.blocked_reason,
                workflow_id: unit.workflow_id,
                job_id: unit.workflow&.job_id,
                waits_on_workflow_id: edges.fetch(unit.id).last
              }
            end
          }
        )
      end
    end

    private

    # { unit_id => [waited-on unit_id, waited-on workflow_id] } for every
    # active unit blocked on a named workflow that has an active unit.
    def wait_edges
      units = WorkUnit.where(state: "blocked").where.not(workflow_id: nil).includes(:workflow).to_a
      units = units.select { |unit| unit.workflow && scope.include_job?(unit.workflow.job_id) } unless scope.all?
      targets = units.to_h { |unit| [ unit, blocking_workflow_id(unit) ] }.compact.select { |_, id| id.positive? }
      return {} if targets.empty?

      target_units = WorkUnit.where(workflow_id: targets.values.uniq, state: WorkUnits::Ownership::ACTIVE_STATES)
                             .pluck(:workflow_id, :id).to_h
      targets.each_with_object({}) do |(unit, workflow_id), edges|
        target = target_units[workflow_id]
        edges[unit.id] = [ target, workflow_id ] if target && target != unit.id
      end
    end

    def blocking_workflow_id(unit)
      from_unit = unit.blocked_details.to_h[BLOCKING_KEY]
      from_artifact = unit.workflow.artifacts.to_h.dig("start_blocked_details", BLOCKING_KEY)
      (from_unit.presence || from_artifact.presence).to_i
    end

    # Every unit has at most one outgoing edge, so each cycle is found by
    # walking forward from each unvisited unit.
    def cycles(edges)
      found = []
      visited = Set.new
      edges.each_key do |start|
        next if visited.include?(start)

        path = []
        on_path = {}
        node = start
        while node && !visited.include?(node) && !on_path.key?(node)
          on_path[node] = path.size
          path << node
          node = edges[node]&.first
        end
        found << path[on_path[node]..] if node && on_path.key?(node)
        visited.merge(path)
      end
      found
    end
  end
end
