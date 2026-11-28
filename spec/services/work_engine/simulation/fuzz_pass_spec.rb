require "rails_helper"
require "tmpdir"

# A small, fixed fuzz pass on every CI run: a handful of fast seed scenarios,
# a fixed seed, and few iterations, so the invariants and the settled-or-
# expected oracle are exercised under perturbation without the cost of a
# real fuzzing budget (bin/simulator --fuzz --iterations 300 locally).
#
# A failure here prints the replay command and writes the minimized
# reproduction; promote it to spec/fixtures/work_engine_simulations/ with a fix.
RSpec.describe "Work-engine simulator fuzz pass" do
  self.use_transactional_tests = false

  SEEDS = %w[
    happy_path_single_job_lands
    worker_died_retries_once
    job_dependency_success
    main_branch_break_then_heal
    provider_usage_pause_then_resume
    already_landed_stack_rebase
  ].freeze
  FUZZ_SEED = 20_261_127
  ITERATIONS = 10

  around do |example|
    Dir.mktmpdir("simulator_fuzz_pass") do |dir|
      @dir = Pathname(dir)
      Rails.logger.silence do
        PerformanceLogging.suppress { example.run }
      end
    end
  end

  before do
    stub_no_workflow_judges
    [ Workflow, Step, Run ].each { |model| allow_any_instance_of(model).to receive(:broadcast_job_progress_event) }
    allow(App::ProviderAvailability).to receive(:broadcast_changed)
  end

  it "keeps every invariant and settles under deterministic perturbations" do
    out = StringIO.new
    paths = SEEDS.map { |name| Rails.root.join("spec/fixtures/work_engine_simulations/#{name}.yml") }

    iterations, failures = WorkEngine::Simulation::Fuzz::Fuzzer.call(
      paths: paths, seed: FUZZ_SEED, iterations: ITERATIONS, output_dir: @dir, out: out
    )

    expect(iterations.size).to eq(ITERATIONS)
    expect(iterations.sum { |iteration| iteration.events.size }).to be >= ITERATIONS
    expect(failures).to be_empty, out.string
  end
end
