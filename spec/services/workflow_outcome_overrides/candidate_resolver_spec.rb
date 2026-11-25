require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::CandidateResolver do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let!(:grader) do
    Step.create!(workflow:, kind: "grader", position: 10, state: "failed", details: {
      "name" => "rspec", "target_label" => "//:grade/rspec", "required" => true,
      "technically_overridable" => true, "command" => "bin/rspec", "exit_code" => 1,
      "output" => "false positive", "source_snapshot" => { "tree_sha" => "b" * 40 },
      "target_fingerprints" => { "command_fingerprint" => "command-v1" }
    })
  end

  before do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "a" * 40)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_BASE_SHA_KEY, "c" * 40)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "plan-v1")
  end

  it "reconstructs an exact technically-overridable grader candidate" do
    candidate = described_class.for_job(job).sole

    expect(candidate.as_json).to include(
      gate_kind: "implementation_grader", gate_identity: "//:grade/rspec",
      candidate_head_sha: "a" * 40, candidate_tree_sha: "b" * 40,
      technically_overridable: true
    )
    expect(candidate.fingerprint.digest).to match(/\A[0-9a-f]{64}\z/)
  end

  it "rejects a stale or invented fingerprint" do
    expect { described_class.new(job).find!("invented") }
      .to raise_error(described_class::NotFound, /stale or unavailable/)
  end
end
