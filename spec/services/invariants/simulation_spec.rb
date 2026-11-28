require "rails_helper"

# The invariants are designed to be asserted by the work-engine simulator after
# every tick. This pins that seam on a happy-path scenario: evaluation runs
# inside the simulated world without raising, without writing, and without
# reporting anything for a scenario that completes cleanly.
RSpec.describe "Invariants in the work-engine simulator" do
  it "hold at every tick of a cleanly succeeding scenario" do
    failures = []
    observer = lambda do |tick|
      report = Invariants.evaluate(now: Time.current)
      failures.concat(report.errors.map { |result| "tick #{tick}: #{result.key} raised #{result.error.class}: #{result.error.message}" })
      failures.concat(report.violations.map { |violation| "tick #{tick}: #{violation.fingerprint}" })
    end

    expect {
      WorkEngine::Simulation::ScenarioRunner.call(
        path: Rails.root.join("spec/fixtures/work_engine_simulations/single_initial_success.yml"),
        max_ticks: 50,
        tick_observer: observer
      )
    }.not_to change(InvariantViolation, :count)

    expect(failures).to be_empty, failures.first(5).join("\n")
  end
end
