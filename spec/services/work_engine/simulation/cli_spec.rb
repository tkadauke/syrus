# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe WorkEngine::Simulation::Cli do
  around do |example|
    Dir.mktmpdir("work_engine_simulations") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def write_scenario(name, contents)
    path = Pathname(@dir).join(name)
    path.write(contents)
    path
  end

  it "runs every scenario in the default directory when no path is supplied" do
    first = write_scenario("a_first.yml", "name: first scenario\n")
    second = write_scenario("b_second.yml", "name: second scenario\nexpected_status: stuck\n")
    stub_const("WorkEngine::Simulation::Cli::DEFAULT_SCENARIO_PATH", Pathname(@dir))

    calls = []
    allow(WorkEngine::Simulation::ScenarioRunner).to receive(:call) do |path:, max_ticks:|
      calls << [ path, max_ticks ]
      WorkEngine::Simulation::Result.new(
        scenario: path == first ? "first scenario" : "second scenario",
        ticks: 1,
        status: path == first ? "success" : "stuck",
        events: [],
        stuck_reasons: path == second ? [ "expected diagnostic" ] : [],
        wait_reasons: [],
        job_ids: [],
        epic_ids: [],
        work_intent_ids: []
      )
    end

    status = described_class.new(argv: [], out: out, err: err).call

    expect(status).to eq(0)
    expect(calls).to eq([ [ first, nil ], [ second, nil ] ])
    expect(out.string).to include("first scenario: success", "second scenario: stuck")
    expect(out.string).to include("work-engine simulations passed (2 scenarios)")
  end

  it "reports a scenario-level exception as that scenario's failure instead of aborting the rest of the batch" do
    write_scenario("a_good.yml", "name: good scenario\n")
    write_scenario("b_broken.yml", "name: broken scenario\n")

    good_result = WorkEngine::Simulation::Result.new(
      scenario: "good scenario",
      ticks: 3,
      status: "success",
      events: [ "job first: queued -> implemented" ],
      stuck_reasons: [],
      wait_reasons: [],
      job_ids: [ 1 ],
      epic_ids: [],
      work_intent_ids: []
    )

    allow(WorkEngine::Simulation::ScenarioRunner).to receive(:call) do |path:, max_ticks:|
      case path.basename.to_s
      when "a_good.yml" then good_result
      when "b_broken.yml"
        raise ArgumentError, "simulation requested alternate provider but only [] is available"
      else
        raise "unexpected scenario path #{path}"
      end
    end

    status = described_class.new(argv: [ @dir ], out: out, err: err).call

    expect(status).to eq(1)
    expect(out.string).to include("good scenario: success after 3 ticks")
    expect(err.string).to include("broken scenario: error after 0 ticks")
    expect(err.string).to include("simulation requested alternate provider but only [] is available")
    expect(err.string).to include("work-engine simulations failed (1/2 scenarios)")
  end

  it "still reports a usage error when argument parsing fails before any scenario runs" do
    status = described_class.new(argv: [ "--max-ticks" ], out: out, err: err).call

    expect(status).to eq(2)
    expect(err.string).to include("missing value for --max-ticks")
    expect(err.string).to include("usage: bin/simulator")
  end
end
