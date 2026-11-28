require "rails_helper"

RSpec.describe Coworkers::RegressionProof do
  let(:owner) { Factories.user }
  let(:job) { Factories.job_record(user: owner, bug_fix: true) }
  let(:workflow) { Workflow.create!(job:, trigger_kind: "initial") }
  let(:grader) do
    Step.create!(workflow:, kind: "grader", state: "succeeded", position: 2,
      details: { "name" => "rspec", "command" => "bundle exec rspec",
        "base_retry" => { "strategy" => "plugin" } })
  end

  before do
    implement = Step.create!(workflow:, kind: "implement", state: "succeeded", position: 1)
    implement.runs.create!(job:, state: "succeeded", trigger_kind: "initial", head_sha: "head")
    grader
    job.diff_review_versions.create!(version_index: 1, base_sha: "base", head_sha: "head", source_key: "final",
      reason: "source_diff", files_snapshot: [{ "path" => "spec/services/fix_spec.rb", "status" => "added" }],
      metadata: {}, truncated: false)
  end

  it "uses the base-revision retry machinery and accepts a spec that fails on base" do
    allow(Syrus::Host::BaseRevisionRetry).to receive(:call).and_return(
      BaseRevisionRetry::Result.new(ran: true, inherited: true, reason: "base_failed", command: "",
        base_failed_identities: [], introduced_failed_identities: [], output: "", method: "full_command")
    )

    result = described_class.call(job)

    expect(result).to be_proven
    expect(Syrus::Host::BaseRevisionRetry).to have_received(:call).with(hash_including(
      workflow:, grader_step: grader, base_sha: "base", command: "bundle exec rspec spec/services/fix_spec.rb",
      require_candidate_pass: true, candidate_files: [ "spec/services/fix_spec.rb" ],
      require_failed_test_evidence: true
    ))
  end

  it "refuses when the new regression spec passes on base" do
    allow(Syrus::Host::BaseRevisionRetry).to receive(:call).and_return(
      BaseRevisionRetry::Result.new(ran: true, inherited: false, reason: "base_passed", command: "",
        base_failed_identities: [], introduced_failed_identities: [], output: "", method: "full_command")
    )

    expect(described_class.call(job)).not_to be_proven
  end

  it "refuses when the new regression spec fails on both branch and base" do
    allow(Syrus::Host::BaseRevisionRetry).to receive(:call).and_return(
      BaseRevisionRetry::Result.new(ran: true, inherited: false, reason: "candidate_command_failed", command: "",
        base_failed_identities: [], introduced_failed_identities: [], output: "", method: "candidate_command")
    )

    expect(described_class.call(job)).not_to be_proven
  end

  it "does not cache an infrastructure failure before the proof ran" do
    allow(Syrus::Host::BaseRevisionRetry).to receive(:call).and_return(
      BaseRevisionRetry::Result.new(ran: false, inherited: false, reason: "base_retry_timed_out", command: "",
        base_failed_identities: [], introduced_failed_identities: [], output: "", method: nil)
    )

    described_class.call(job)

    expect(workflow.artifact("coworker_regression_proof")).to be_nil
  end
end
