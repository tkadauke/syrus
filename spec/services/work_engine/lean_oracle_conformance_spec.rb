require "rails_helper"

# DOC-44 Phase 2, fixture conformance: each work-engine simulation scenario is
# loaded, exported in the kernel's canonical schema (WorkEngine::CanonicalWorld)
# and diagnosed by both the Ruby reconciler and the Lean oracle
# (formal/Oracle.lean). Both diagnoses are projected onto the targets the
# kernel models (spec/support/lean_oracle.rb) and compared.
RSpec.describe "Lean oracle conformance", :work_engine_simulation_assertions, if: LeanOracle.available? do
  def compare(label)
    world = WorkEngine::CanonicalWorld.export
    report = LeanOracle.call(world)
    expect(report.fetch("valid")).to be(true), "#{label}: exported world is not valid for the kernel"
    expect(report.fetch("next_state_issues")).to be_empty

    ruby = LeanOracle.ruby_targets(WorkEngine::Reconciler.call(source: "lean_oracle_conformance_spec"))
    [ label, LeanOracle.kernel_targets(world, report), ruby ]
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
