require "rails_helper"

RSpec.describe Invariants::RetryStorms do
  let(:job) { Factories.job_record(state: "landing") }

  # One failed attempt: a fresh Workflow whose `kind` step failed with the
  # given error, the way each automatic retry produces one.
  def failed_attempt(kind: "prepare", message:, classification: "provider_transient", retryable: true, at: Time.current)
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "initial", state: "failed", finished_at: at)
    step = Step.create!(workflow: workflow, kind: kind, position: 0, state: "failed")
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "skipped")
    run.update_columns(state: "failed", finished_at: at)
    RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: message)
    record = RunFailureClassification.find_or_initialize_by(run_id: run.id)
    record.update!(classification: classification, retryable: retryable, confidence: 0.9, classified_at: at)
    run
  end

  def native_gem_failure(workflow_id)
    "prepare command failed (exit 5) in /var/lib/syrus/workflows/#{workflow_id}: bundle install -- mysql2 extconf.rb failed"
  end

  it "reports the same deterministic failure retried more than the limit inside the window" do
    runs = 6.times.map { |index| failed_attempt(message: native_gem_failure(1000 + index), at: index.minutes.ago) }

    violations = described_class.call(now: Time.current)

    expect(violations.size).to eq(1)
    storm = violations.first
    expect(storm.severity).to eq("critical")
    expect(storm.subject_id).to eq(job.id)
    expect(storm.details).to include("step_kind" => "prepare", "failures" => 6, "classification" => "provider_transient", "retryable" => true)
    expect(storm.affected_ids["run_ids"]).to match_array(runs.map(&:id))
    expect(storm.message).to include(job.slug, "prepare", "6")
  end

  it "does not report failures at or under the limit" do
    5.times { |index| failed_attempt(message: native_gem_failure(index)) }

    expect(described_class.call(now: Time.current)).to be_empty
    expect(described_class.call(now: Time.current, max_failures: 4).size).to eq(1)
  end

  it "does not count failures outside the window" do
    3.times { |index| failed_attempt(message: native_gem_failure(index)) }
    3.times { |index| failed_attempt(message: native_gem_failure(index), at: 2.hours.ago) }

    expect(described_class.call(now: Time.current)).to be_empty
  end

  it "keeps different failures apart" do
    3.times { |index| failed_attempt(message: native_gem_failure(index)) }
    3.times { failed_attempt(message: "network unreachable", classification: "network_error") }

    expect(described_class.call(now: Time.current)).to be_empty
  end

  it "counts one error together when the classifier labels it differently from run to run" do
    3.times { |index| failed_attempt(message: native_gem_failure(index), classification: "provider_transient") }
    3.times { |index| failed_attempt(message: native_gem_failure(index), classification: "timeout") }

    storm = described_class.call(now: Time.current).sole

    expect(storm.details).to include("failures" => 6, "classifications" => { "provider_transient" => 3, "timeout" => 3 }, "retryable" => true)
  end

  it "keeps different step kinds apart" do
    3.times { |index| failed_attempt(message: native_gem_failure(index)) }
    3.times { |index| failed_attempt(kind: "implement", message: native_gem_failure(index)) }

    expect(described_class.call(now: Time.current)).to be_empty
  end

  it "is only a warning when the failure is already classified as not retryable" do
    6.times { |index| failed_attempt(message: native_gem_failure(index), classification: "application_error", retryable: false) }

    expect(described_class.call(now: Time.current).map(&:severity)).to eq([ "warning" ])
  end
end
