require "open3"

# DOC-44 Phase 2: the Lean oracle (formal/Oracle.lean) and the projection that
# compares its diagnosis with the Ruby reconciler's. Both are reduced to the
# targets the kernel models -- Workflows whose descendants need cleanup, units
# that must take their Workflow's outcome, units whose locks must go.
#
# Specs using it run only where the oracle has been built (`cd formal && lake
# build syrus_oracle`), so the regular suite does not need Lean.
module LeanOracle
  BINARY = Rails.root.join("formal/.lake/build/bin/syrus_oracle")
  ACTIVE_RUN_STATES = %w[queued running].freeze

  module_function

  def available?
    BINARY.executable?
  end

  def call(world)
    out, status = Open3.capture2(BINARY.to_s, stdin_data: JSON.generate(world))
    raise "oracle failed (#{status.exitstatus}): #{out}" unless status.success?

    JSON.parse(out)
  end

  def empty_targets
    { cleanup_workflows: Set.new, outcome_units: Set.new, lock_units: Set.new }
  end

  # Kernel issues projected onto modelled targets, with the two documented
  # ordering exceptions applied.
  def kernel_targets(world, report)
    step_workflow = world.fetch("steps").to_h { |step| [ step.fetch("id"), step.fetch("workflow") ] }
    run_workflow = world.fetch("runs").to_h { |run| [ run.fetch("id"), step_workflow[run.fetch("step")] ] }
    lock_unit = world.fetch("locks").to_h { |lock| [ lock.fetch("key"), lock.fetch("unit") ] }
    targets = empty_targets
    report.fetch("issues").each do |issue|
      kind, body = issue.first
      case kind
      when "activeRunUnderTerminalWorkflow", "activeRunOnTerminalStep"
        targets[:cleanup_workflows] << run_workflow[body.fetch("run")]
      when "activeStepUnderTerminalWorkflow" then targets[:cleanup_workflows] << step_workflow[body.fetch("step")]
      when "activeUnitBehindTerminalWorkflow" then targets[:outcome_units] << body.fetch("unit")
      when "lockOfInactiveUnit" then targets[:lock_units] << lock_unit[body.fetch("key")]
      end
    end

    # Ordering exception 1: a unit taking its Workflow's outcome loses its
    # locks in the same repair (WorkUnit#mark_terminal! releases them), so Ruby
    # reports only the outcome; the kernel's lock issue is implied by it.
    targets[:lock_units] -= targets[:outcome_units]

    # Ordering exception 2: the kernel gives a unit its Workflow's outcome in
    # the same pass that cleans up that Workflow's Runs. Ruby waits for the
    # Runs first (`next if workflow.runs.active.exists?`) and reports the
    # outcome on a later pass, so while the Workflow still has active Runs the
    # kernel's outcome issue is not yet a Ruby issue.
    busy_workflows = world.fetch("runs").select { |run| ACTIVE_RUN_STATES.include?(run.fetch("state")) }
                          .to_set { |run| run_workflow[run.fetch("id")] }
    targets[:outcome_units] -= world.fetch("units").select { |unit| busy_workflows.include?(unit["workflow"]) }
                                    .map { |unit| unit.fetch("id") }
    targets
  end

  # Ruby issues projected onto the same targets.
  def ruby_targets(result)
    targets = empty_targets
    result.issues.each do |issue|
      case issue.kind
      when "cleanup_blocked_by_active_descendants", "active_run_on_terminal_step"
        targets[:cleanup_workflows].merge(issue.affected_ids[:workflow_ids])
      when "active_work_unit_terminal_workflow_locks"
        targets[:outcome_units].merge(issue.affected_ids[:work_unit_ids])
      when "terminal_work_unit_active_locks"
        targets[:lock_units].merge(issue.affected_ids[:work_unit_ids])
      end
    end
    targets
  end
end
