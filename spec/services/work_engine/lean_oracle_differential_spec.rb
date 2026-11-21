require "rails_helper"

# DOC-44 Phase 2, generated differential testing: random worlds built from
# real records are diagnosed by the Ruby reconciler and the Lean oracle, and
# any disagreement is shrunk to a minimal list of mutations.
#
# A world is two launched Workflows plus a seeded list of mutations (a
# Workflow, Step or unit state, or an extra Run on a Step). Timestamps are an
# hour old so no grace period can explain a difference. On a mismatch the
# shrinker drops mutations one at a time while the disagreement persists and
# reports the minimal list with its seed, ready to become a fixture.
#
# Runs only where the oracle has been built. SYRUS_LEAN_DIFF_WORLDS and
# SYRUS_LEAN_DIFF_SEED widen or replay a run.
RSpec.describe "Lean oracle differential testing", :work_engine_simulation_assertions, if: LeanOracle.available? do
  WORKFLOW_STATES = %w[queued running succeeded failed cancelled blocked].freeze
  STEP_STATES = %w[queued running succeeded failed cancelled skipped].freeze
  RUN_STATES = %w[queued running succeeded failed cancelled].freeze
  UNIT_STATES = %w[queued blocked running succeeded failed cancelled].freeze

  def random_mutations(rng, count)
    Array.new(count) do
      case rng.rand(4)
      when 0 then [ :workflow, rng.rand(2), WORKFLOW_STATES.sample(random: rng) ]
      when 1 then [ :step, rng.rand(2), rng.rand(3), STEP_STATES.sample(random: rng) ]
      when 2 then [ :run, rng.rand(2), rng.rand(3), RUN_STATES.sample(random: rng) ]
      else [ :unit, rng.rand(2), UNIT_STATES.sample(random: rng) ]
      end
    end
  end

  # Builds the world for a mutation list inside a savepoint and returns the
  # two projections; everything is rolled back afterwards.
  def diagnose(mutations)
    outcome = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      workflows = Array.new(2) do
        job = Factories.job_record(state: "running")
        WorkUnits::Launcher.instantiate(kind: "initial", job: job).tap do |workflow|
          workflow.update_columns(state: "running", started_at: 1.hour.ago, created_at: 1.hour.ago, updated_at: 1.hour.ago)
        end
      end
      apply!(workflows, mutations)
      world = WorkEngine::CanonicalWorld.export
      report = LeanOracle.call(world)
      raise "generated world is not valid for the kernel: #{world}" unless report.fetch("valid")

      ruby = LeanOracle.ruby_targets(WorkEngine::Reconciler.call(source: "lean_oracle_differential_spec", now: Time.current))
      outcome = [ LeanOracle.kernel_targets(world, report), ruby ]
      raise ActiveRecord::Rollback
    end
    outcome
  end

  def apply!(workflows, mutations)
    mutations.each do |kind, *args|
      case kind
      when :workflow
        index, state = args
        finished = %w[succeeded failed cancelled blocked].include?(state) ? 1.hour.ago : nil
        workflows[index].update_columns(state: state, finished_at: finished, updated_at: 1.hour.ago)
      when :step
        index, position, state = args
        step = workflows[index].steps.order(:position, :id).offset(position).first
        step&.update_columns(state: state, updated_at: 1.hour.ago,
                             finished_at: %w[succeeded failed cancelled skipped].include?(state) ? 1.hour.ago : nil)
      when :run
        index, position, state = args
        step = workflows[index].steps.order(:position, :id).offset(position).first
        next unless step

        step.runs.create!(job: workflows[index].job, trigger_kind: workflows[index].trigger_kind, agent_provider: "claude",
                          state: state, created_at: 1.hour.ago, updated_at: 1.hour.ago,
                          started_at: (1.hour.ago unless state == "queued"),
                          finished_at: (1.hour.ago if %w[succeeded failed cancelled].include?(state)))
      when :unit
        index, state = args
        workflows[index].work_unit.update_columns(state: state, updated_at: 1.hour.ago,
                                                   finished_at: %w[succeeded failed cancelled].include?(state) ? 1.hour.ago : nil)
      end
    end
  end

  def mismatch?(mutations)
    kernel, ruby = diagnose(mutations)
    kernel != ruby
  end

  def shrink(mutations)
    current = mutations
    loop do
      smaller = current.each_index.lazy.map { |i| current[0...i] + current[(i + 1)..] }.find { |candidate| mismatch?(candidate) }
      break current unless smaller

      current = smaller
    end
  end

  # Minimal disagreements the generator found, kept as permanent fixtures.
  # Each names how it was resolved.
  {
    # Kernel gap: the first kernel left an active Run on a finished Step of a
    # live Workflow alone; Ruby skips it (`active_run_on_terminal_step`).
    "an active Run on a skipped Step of a live Workflow" => [ [ :step, 1, 1, "skipped" ], [ :run, 1, 1, "queued" ] ],
    # Ordering exception: Ruby gives the unit its outcome only once the
    # cancelled Workflow's Runs are gone; the kernel does both in one pass.
    "a running Run under a cancelled Workflow" => [ [ :run, 1, 0, "running" ], [ :workflow, 1, "cancelled" ] ]
  }.each do |name, mutations|
    it "agrees on #{name}" do
      kernel, ruby = diagnose(mutations)

      expect(kernel).to eq(ruby)
      expect(kernel.values).to include(be_present)
    end
  end

  it "finds no disagreement between the Ruby reconciler and the oracle on generated worlds" do
    seed = Integer(ENV.fetch("SYRUS_LEAN_DIFF_SEED", Random.new_seed))
    worlds = Integer(ENV.fetch("SYRUS_LEAN_DIFF_WORLDS", 25))
    rng = Random.new(seed)
    failures = []

    worlds.times do |index|
      mutations = random_mutations(rng, 1 + rng.rand(6))
      next unless mismatch?(mutations)

      minimal = shrink(mutations)
      kernel, ruby = diagnose(minimal)
      failures << "world #{index} (seed #{seed}): mutations=#{minimal.inspect} kernel=#{kernel.transform_values(&:to_a)} ruby=#{ruby.transform_values(&:to_a)}"
    end

    expect(failures).to be_empty, failures.uniq.first(10).join("\n")
  end
end
