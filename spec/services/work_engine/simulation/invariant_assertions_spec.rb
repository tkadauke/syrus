require "rails_helper"

RSpec.describe WorkEngine::Simulation::InvariantAssertions do
  def violation(invariant: "zombie_workflows", subject_id: 7, discriminator: "zombie_workflow", job_ids: [ 3 ])
    Invariants::Violation.new(
      invariant: invariant,
      severity: :critical,
      subject_type: "Workflow",
      subject_id: subject_id,
      discriminator: discriminator,
      message_params: { subject: "WF-#{subject_id}", condition: discriminator, state: "running", hours: 0.0 },
      details: { condition: discriminator },
      affected_ids: { job_ids: job_ids }
    )
  end

  def report(*violations)
    result = Invariants::Report::Result.new(
      invariant: Invariants::ZombieWorkflows, options: {}, violations: violations, error: nil, duration_ms: 0
    )
    Invariants::Report.new(evaluated_at: Time.current, scope: Invariants::Scope.for_jobs([ 3 ]), results: [ result ])
  end

  def stub_reports(*reports)
    allow(Invariants).to receive(:evaluate).and_return(*reports)
  end

  it "evaluates every invariant scoped to the scenario's Jobs with wall-clock thresholds zeroed" do
    stub_reports(report)

    described_class.build({}, job_ids: [ 3, 4 ]).observe!(0)

    expect(Invariants).to have_received(:evaluate) do |now:, scope:, only:, options:|
      expect(scope.job_ids).to eq([ 3, 4 ])
      expect(only).to match_array(Invariants.keys)
      expect(options.fetch("zombie_workflows")).to eq(threshold: 0.seconds, blocked_threshold: 0.seconds)
      expect(options.fetch("slot_holders")).to eq(grace: 0.seconds)
      # A count over a window, not an age: keeps its production window.
      expect(options.fetch("retry_storms")).to eq({})
    end
  end

  it "fails a violation only once it has held for its sustain window of consecutive ticks" do
    stub_reports(report(violation), report(violation), report, report(violation), report(violation), report(violation))
    assertions = described_class.build({ "sustain" => { "zombie_workflows" => 3 } }, job_ids: [ 3 ])

    results = 6.times.map { |tick| assertions.observe!(tick) }

    # Seen at ticks 0-1, repaired at tick 2, back at 3-5: only the second
    # streak lasts three ticks.
    expect(results.first(5)).to all(be_empty)
    expect(results.last).to contain_exactly(a_string_including("tick 5: invariant zombie_workflows", "held ticks 3..5"))
  end

  it "ignores violations the scenario declares as expected" do
    stub_reports(report(violation), report(violation(invariant: "zombie_workflows", job_ids: [ 9 ])))
    assertions = described_class.build(
      { "sustain" => { "zombie_workflows" => 1 }, "expected" => [ { "invariant" => "zombie_workflows", "job" => 3, "reason" => "modelled" } ] },
      job_ids: [ 3 ]
    )

    expect(assertions.observe!(0)).to be_empty
    expect(assertions.observe!(1)).to contain_exactly(a_string_including("invariant zombie_workflows"))
  end

  it "counts every violation still present when a quiescent scenario ends, however briefly it was seen" do
    stub_reports(report(violation))
    assertions = described_class.build({}, job_ids: [ 3 ])

    expect(assertions.finish!(4, quiescent: true)).to contain_exactly(a_string_including("still present when the scenario ended"))
  end

  it "does not re-evaluate a scenario that ended while work was still moving" do
    stub_reports(report(violation))

    expect(described_class.build({}, job_ids: [ 3 ]).finish!(4, quiescent: false)).to be_empty
    expect(Invariants).not_to have_received(:evaluate)
  end

  it "fails when a required expected violation never appeared" do
    stub_reports(report)
    assertions = described_class.build(
      { "expected" => [ { "invariant" => "failed_blockers", "required" => true } ] },
      job_ids: [ 3 ]
    )
    assertions.observe!(0)

    expect(assertions.finish!(0, quiescent: true)).to contain_exactly("expected invariant violation never observed: failed_blockers")
  end

  it "reports an invariant that raised as a failure" do
    errored = Invariants::Report::Result.new(
      invariant: Invariants::SlotHolders, options: {}, violations: [], error: RuntimeError.new("boom"), duration_ms: 0
    )
    stub_reports(Invariants::Report.new(evaluated_at: Time.current, scope: Invariants::Scope.all, results: [ errored ]))

    expect(described_class.build({}, job_ids: [ 3 ]).observe!(2)).to contain_exactly("tick 2: invariant slot_holders raised RuntimeError: boom")
  end

  it "rejects unknown invariant keys" do
    expect { described_class.build({ "only" => [ "no_such_invariant" ] }, job_ids: [ 3 ]) }.to raise_error(Invariants::UnknownInvariant)
    expect { described_class.build({ "expected" => [ { "invariant" => "nope" } ] }, job_ids: [ 3 ]) }.to raise_error(Invariants::UnknownInvariant)
  end
end
