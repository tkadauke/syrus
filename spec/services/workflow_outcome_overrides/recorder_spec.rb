require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Recorder do
  let(:user) { Factories.user }
  let(:job) { Factories.job(user:) }
  let(:workflow) { job.workflows.last }
  let!(:grader) do
    Step.create!(workflow:, kind: "grader", position: 10, state: "failed", details: {
      "name" => "lint", "required" => true, "technically_overridable" => true,
      "command" => "bin/lint", "exit_code" => 1, "output" => "known false positive"
    })
  end

  before do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "a" * 40)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "plan-v1")
  end

  it "records the authorized actor, reason, decision, and exact evidence once" do
    candidate = WorkflowOutcomeOverrides::CandidateResolver.for_job(job).sole
    arguments = {
      job:, fingerprint_digest: candidate.fingerprint.digest, actor: user,
      channel: "agent", reason: "The configured check is demonstrably incorrect",
      permission_decision: { "decision" => "confirmed" }
    }

    first = described_class.call(**arguments)
    second = described_class.call(**arguments)

    expect(second).to eq(first)
    expect(first).to have_attributes(actor: user, reason: arguments[:reason],
      evidence_digest: candidate.gate_failure[:evidence_digest], channel: "agent")
    expect(first.permission_decision).to eq("decision" => "confirmed")
  end

  it "requires an audit reason" do
    candidate = WorkflowOutcomeOverrides::CandidateResolver.for_job(job).sole
    expect {
      described_class.call(job:, fingerprint_digest: candidate.fingerprint.digest, actor: user,
        channel: "agent", reason: " ", permission_decision: {})
    }.to raise_error(described_class::InvalidRequest, /reason is required/)
  end
end
