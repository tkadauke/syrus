require "rails_helper"

RSpec.describe Invariants::Recorder do
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }

  def violation(subject_id, invariant: "landing_progress")
    Invariants::Violation.new(invariant: invariant, severity: :critical, subject_type: "Job", subject_id: subject_id,
                              message_params: { job: "JOB-#{subject_id}", state: "approved", hours: 3 }, details: { "n" => subject_id },
                              since: t0 - 3.hours)
  end

  def report(at:, violations: [], errors: {})
    results = Invariants.registry.map do |invariant|
      Invariants::Report::Result.new(invariant: invariant, options: invariant.defaults,
                                     violations: violations.select { |v| v.invariant == invariant.key },
                                     error: errors[invariant.key], duration_ms: 1)
    end
    Invariants::Report.new(evaluated_at: at, scope: Invariants::Scope.all, results: results)
  end

  it "opens, refreshes, and resolves violation episodes by fingerprint" do
    first = described_class.record!(report(at: t0, violations: [ violation(1), violation(2) ]))
    expect(first.opened.size).to eq(2)

    second = described_class.record!(report(at: t0 + 15.minutes, violations: [ violation(1) ]))
    expect(second.refreshed.map(&:subject_id)).to eq([ 1 ])
    expect(second.resolved.map(&:subject_id)).to eq([ 2 ])

    ongoing = InvariantViolation.open.sole
    expect(ongoing).to have_attributes(subject_id: 1, first_detected_at: t0, last_detected_at: t0 + 15.minutes, detection_count: 2,
                                       violating_since: t0 - 3.hours)
    expect(InvariantViolation.resolved.sole).to have_attributes(subject_id: 2, resolved_at: t0 + 15.minutes, open_fingerprint: nil)
  end

  it "opens a new episode when a resolved violation recurs" do
    described_class.record!(report(at: t0, violations: [ violation(1) ]))
    described_class.record!(report(at: t0 + 15.minutes))
    described_class.record!(report(at: t0 + 30.minutes, violations: [ violation(1) ]))

    expect(InvariantViolation.where(fingerprint: violation(1).fingerprint).count).to eq(2)
    expect(InvariantViolation.open.sole.first_detected_at).to eq(t0 + 30.minutes)
  end

  it "does not resolve the violations of an invariant that raised" do
    described_class.record!(report(at: t0, violations: [ violation(1) ]))

    outcome = described_class.record!(report(at: t0 + 15.minutes, errors: { "landing_progress" => RuntimeError.new("boom") }))

    expect(outcome.resolved).to be_empty
    expect(InvariantViolation.open.count).to eq(1)
  end

  it "refuses a scoped evaluation" do
    scoped = Invariants::Report.new(evaluated_at: t0, scope: Invariants::Scope.for_jobs([ 1 ]), results: [])

    expect { described_class.record!(scoped) }.to raise_error(ArgumentError)
  end
end
