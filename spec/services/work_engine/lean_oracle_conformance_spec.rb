require "rails_helper"
require "open3"

# DOC-44 Phase 2, fixture conformance: each work-engine simulation scenario is
# loaded, exported in the kernel's canonical schema (WorkEngine::CanonicalWorld)
# and diagnosed by both the Ruby reconciler and the Lean oracle
# (formal/Oracle.lean). Both diagnoses are projected onto the targets the
# kernel models -- Workflows whose descendants need cleanup, units that must
# take their Workflow's outcome, units whose locks must go -- and compared.
#
# Runs only where the oracle has been built (`cd formal && lake build
# syrus_oracle`), so the regular suite does not need Lean.
ORACLE_BINARY = Rails.root.join("formal/.lake/build/bin/syrus_oracle")

RSpec.describe "Lean oracle conformance", :work_engine_simulation_assertions, if: ORACLE_BINARY.executable? do
  def oracle(world)
    out, status = Open3.capture2(ORACLE_BINARY.to_s, stdin_data: JSON.generate(world))
    raise "oracle failed (#{status.exitstatus}): #{out}" unless status.success?

    JSON.parse(out)
  end

  # Kernel issues projected onto modelled targets.
  def kernel_targets(world, report)
    step_workflow = world.fetch("steps").to_h { |step| [ step.fetch("id"), step.fetch("workflow") ] }
    run_workflow = world.fetch("runs").to_h { |run| [ run.fetch("id"), step_workflow[run.fetch("step")] ] }
    lock_unit = world.fetch("locks").to_h { |lock| [ lock.fetch("key"), lock.fetch("unit") ] }
    targets = { cleanup_workflows: Set.new, outcome_units: Set.new, lock_units: Set.new }
    report.fetch("issues").each do |issue|
      kind, body = issue.first
      case kind
      when "activeRunUnderTerminalWorkflow" then targets[:cleanup_workflows] << run_workflow[body.fetch("run")]
      when "activeStepUnderTerminalWorkflow" then targets[:cleanup_workflows] << step_workflow[body.fetch("step")]
      when "activeUnitBehindTerminalWorkflow" then targets[:outcome_units] << body.fetch("unit")
      when "lockOfInactiveUnit" then targets[:lock_units] << lock_unit[body.fetch("key")]
      end
    end
    # A unit taking its Workflow's outcome loses its locks in the same repair
    # (WorkUnit#mark_terminal! releases them), so Ruby reports only the
    # outcome; the kernel's lock issue for that unit is implied by it.
    targets[:lock_units] -= targets[:outcome_units]
    targets
  end

  # Ruby issues projected onto the same targets.
  def ruby_targets(result)
    targets = { cleanup_workflows: Set.new, outcome_units: Set.new, lock_units: Set.new }
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

  def compare(label)
    world = WorkEngine::CanonicalWorld.export
    report = oracle(world)
    expect(report.fetch("valid")).to be(true), "#{label}: exported world is not valid for the kernel"
    expect(report.fetch("next_state_issues")).to be_empty

    ruby = ruby_targets(WorkEngine::Reconciler.call(source: "lean_oracle_conformance_spec"))
    [ label, kernel_targets(world, report), ruby ]
  end

  it "agrees with the Ruby reconciler on every simulation scenario's starting world" do
    paths = Dir[Rails.root.join("spec/fixtures/work_engine_simulations/*.yml")].sort
    rows = paths.map do |path|
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        WorkEngine::Simulation::ScenarioLoader.load!(path)
        result = compare(File.basename(path, ".yml"))
        raise ActiveRecord::Rollback
      end
      result
    end

    mismatches = rows.reject { |_label, kernel, ruby| kernel == ruby }
    expect(rows).not_to be_empty
    # Every mismatch becomes a kernel fix or a documented exception (DOC-44,
    # "Drift prevention"); none are outstanding.
    expect(mismatches).to be_empty, mismatches.map { |label, kernel, ruby|
      "#{label}: kernel=#{kernel.transform_values(&:to_a)} ruby=#{ruby.transform_values(&:to_a)}"
    }.join("\n")
  end
  # The same comparison at the start of every simulation tick, before the
  # Ruby reconciler acts, so the intermediate worlds the engine actually
  # passes through are covered and not only each scenario's starting state.
  Dir[Rails.root.join("spec/fixtures/work_engine_simulations/*.yml")].sort.each do |path|
    scenario = File.basename(path, ".yml")

    it "agrees with the Ruby reconciler at every tick of #{scenario}" do
      mismatches = []
      observer = lambda do |tick|
        label, kernel, ruby = compare("#{scenario}@#{tick}")
        mismatches << "#{label}: kernel=#{kernel.transform_values(&:to_a)} ruby=#{ruby.transform_values(&:to_a)}" if kernel != ruby
      end

      WorkEngine::Simulation::ScenarioRunner.call(path: path, max_ticks: 50, tick_observer: observer)

      expect(mismatches).to be_empty, mismatches.first(5).join("\n")
    end
  end
end
