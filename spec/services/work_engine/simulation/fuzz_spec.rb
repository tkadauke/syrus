require "rails_helper"
require "tmpdir"

RSpec.describe WorkEngine::Simulation::Fuzz do
  around do |example|
    Dir.mktmpdir("simulator_fuzz") do |dir|
      @dir = Pathname(dir)
      example.run
    end
  end

  let(:out) { StringIO.new }
  let(:seed_path) do
    @dir.join("seed.yml").tap do |path|
      path.write(<<~YAML)
        name: fuzz seed
        jobs:
          first:
            title: First
            state: queued
          second:
            title: Second
            state: queued
        events:
          - name: scripted approval
            when: { job: { id: first, state: implemented } }
            do: { approve: first }
      YAML
    end
  end

  def result(status:, ticks: 10, final_states: { "JOB-1" => "implemented" }, stuck_reasons: [], invariant_violations: [])
    WorkEngine::Simulation::Result.new(
      scenario: "fuzz seed", ticks: ticks, status: status, events: [], stuck_reasons: stuck_reasons,
      wait_reasons: [], job_ids: [], epic_ids: [], work_intent_ids: [],
      invariant_violations: invariant_violations, final_states: final_states
    )
  end

  # Stands in for the simulator: the run fails while any injected operator
  # pause is present, the way a pause-held slot would stall a real scenario.
  let(:runs) { [] }
  let(:runner) do
    lambda do |file|
      data = YAML.safe_load(file.read, aliases: false)
      injected = Array(data["events"]).select { |event| event["fuzz"] }
      runs << injected.map { |event| event["fuzz"] }
      if injected.any? { |event| event["fuzz"] == "pause" }
        result(status: "stuck", final_states: { "JOB-1" => "running" }, stuck_reasons: [ "no state changed" ])
      else
        result(status: "success")
      end
    end
  end

  def fuzzer(**options)
    described_class::Fuzzer.new(paths: [ seed_path ], output_dir: @dir.join("out"), out: out, runner: runner, **options)
  end

  describe "deterministic replay" do
    it "plans the same perturbations for the same seed and iteration" do
      first = fuzzer(seed: 7).plan(3, [ seed_path ])
      again = fuzzer(seed: 7).plan(3, [ seed_path ])

      expect(again).to eq(first)
      expect(first.last).to all(include("fuzz", "when", "do"))
      # Scheduled inside the seed's own timeline (its baseline ran 10 ticks).
      ticks = first.last.map { |event| event.dig("when", "tick", "at_least") || event.dig("when", "all", 0, "tick", "at_least") }
      expect(ticks).to all(be_between(0, 20))
    end

    it "plans different perturbations for different seeds" do
      plans = (1..8).map { |seed| fuzzer(seed: seed).plan(0, [ seed_path ]).last }

      expect(plans.uniq.size).to be > 1
    end

    it "replays a single iteration by index" do
      iterations, = fuzzer(seed: 3, iterations: 20, only_iteration: 5).call

      expect(iterations.map(&:index)).to eq([ 5 ])
      expect(iterations.first.events).to eq(fuzzer(seed: 3).plan(5, [ seed_path ]).last)
    end
  end

  describe described_class::Catalog do
    it "aims only Job-free perturbations at a seed without Jobs" do
      context = described_class.context_for({ "work_intents" => { "intent" => {} } }, ticks: 5)
      events = described_class.new(Random.new(4), context).draw(40)

      expect(events.map { |event| event["fuzz"] }.uniq).to all(satisfy { |kind| !kind.match?(/pause|approve|transient|worker_died/) })
      expect(events.to_json).not_to include('"job":null')
    end

    it "draws every catalog perturbation as events the runner knows" do
      context = described_class.context_for({ "jobs" => { "a" => {}, "b" => {} }, "runtime" => { "workers" => [ "w1" ] } }, ticks: 8)
      catalog = described_class.new(Random.new(7), context)
      known = %w[
        advance_main approve inject_outcome break_main_branch heal_main_branch exhaust_provider_usage refresh_provider_usage
        wake_provider_admission set_pr_checks report_ci_failure merge_pr set_job_provider resume_deferred_phase wake pause_work
        unpause_work lose_worker deploy_restart github_outage join_worker leave_worker
      ]

      events = catalog.kinds.uniq.flat_map { |kind| catalog.send(:build, kind, 0) }

      expect(events.flat_map { |event| event["do"].keys }.uniq - known).to be_empty
      expect(events.map { |event| event["fuzz"] }).to include("deploy_restart", "github_outage", "main_churn", "operator_race", "join_worker")
      churn = events.select { |event| event["fuzz"] == "main_churn" }
      expect(churn.size).to be >= 3
      expect(churn.map { |event| event.dig("when", "tick", "at_least") }).to eq(churn.map { |event| event.dig("when", "tick", "at_least") }.sort)
      race = events.select { |event| event["fuzz"] == "operator_race" }
      expect(race.map { |event| event.dig("when", "tick", "at_least") }.uniq.size).to eq(1)
    end
  end

  describe "failures" do
    it "shrinks a failing iteration to the injected events that matter and writes a reproduction" do
      iterations, failures = fuzzer(seed: 11, iterations: 40).call
      failing = iterations.select(&:signature)
      expect(failing).not_to be_empty
      expect(failures.size).to eq(failing.size)

      failure = failures.first
      expect(failure.minimized_events.map { |event| event["fuzz"] }).to eq([ "pause" ])
      expect(failure.reproduced).to be(true)

      repro = YAML.safe_load(failure.repro_path.read, aliases: false)
      expect(repro.fetch("fuzz")).to include("seed" => 11, "iteration" => failure.iteration.index, "signature" => "stuck:no state changed")
      # The seed's own scripted events stay; only the minimized injections are added.
      expect(repro.fetch("events").map { |event| event["name"] }).to eq([ "scripted approval", failure.minimized_events.first["name"] ])
      expect(out.string).to include("replay: bin/simulator --fuzz --seed 11 --iteration #{failure.iteration.index}")
    end

    it "skips a seed whose unperturbed baseline does not pass" do
      broken = lambda { |_file| result(status: "stuck", final_states: { "JOB-1" => "queued" }, stuck_reasons: [ "no state changed" ]) }
      fuzz = described_class::Fuzzer.new(paths: [ seed_path ], output_dir: @dir.join("out"), out: out, runner: broken)

      expect { fuzz.call }.to raise_error(ArgumentError, /no seed scenario passed/)
      expect(out.string).to include("skipping seed")
    end
  end

  describe described_class::Oracle do
    def signature(result) = described_class.failure_signature(result, expected_statuses: %w[success waiting])

    it "passes the seed's expected status" do
      expect(signature(result(status: "success"))).to be_nil
    end

    it "passes a quiet world where every Job names why it stopped" do
      settled = result(status: "stuck", final_states: { "JOB-1" => "closed", "JOB-2" => "failed", "JOB-3" => "implemented" },
                       stuck_reasons: [ "no state changed" ])

      expect(signature(settled)).to be_nil
    end

    it "fails a quiet world that left a Job queued or running" do
      stalled = result(status: "stuck", final_states: { "JOB-1" => "closed", "JOB-2" => "running" }, stuck_reasons: [ "no state changed" ])

      expect(signature(stalled)).to eq("stuck:no state changed")
    end

    it "passes a quiet world whose remaining Job an operator is holding" do
      held = result(status: "stuck", final_states: { "JOB-1" => "running:manual_paused" }, stuck_reasons: [ "no state changed" ])

      expect(signature(held)).to be_nil
    end

    it "fails on invariant violations, keyed by invariant" do
      violated = result(status: "violated", invariant_violations: [ "tick 4: invariant slot_holders WorkUnit:3:rebase_slot held ticks 2..4: x" ])

      expect(signature(violated)).to eq("invariant:slot_holders")
    end
  end
end
