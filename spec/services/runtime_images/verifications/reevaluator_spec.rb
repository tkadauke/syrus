require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::Reevaluator do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:image) do
    namespace = RuntimeImageNamespace.create!(name: "reevaluator/spec", owner_kind: "test", owner_ref: "1", provider_key: provider.key)
    RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image")
  end
  let(:policy) { { "checks" => [ { "key" => "manifest", "required" => true } ], "version" => 1 } }
  let(:attempt) { image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "accepted", decision: "candidate", policy_snapshot: policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy), started_at: 1.hour.ago, finished_at: 1.hour.ago) }
  let(:attestation) { attempt.create_attestation!(runtime_image: image, image_digest: image.digest, policy_digest: attempt.policy_digest, evidence_digest: image.digest, outcome: "accepted", issued_at: 1.hour.ago, expires_at: 1.day.from_now) }
  let(:orchestrator) { instance_double(RuntimeImages::Verifications::Orchestrator) }
  let(:runner) { instance_double(RuntimeImages::Builds::Runner) }
  subject(:service) { described_class.new(orchestrator: orchestrator, build_runner: runner) }
  it "detects expiry, database changes, and required-check changes" do
    changed = policy.deep_dup.tap { |value| value["checks"] << { "key" => "image_policy", "required" => true } }
    expect(service.due?(attestation, policy: changed, database_version: nil)).to be(true)
    expect(service.due?(attestation, policy: policy, database_version: "new-db")).to be(true)
  end
  it "keeps a failed pre-verification reevaluation retryable" do
    result = instance_double(RuntimeImageBuildResult, request: instance_double(RuntimeImageBuildRequest, evidences: []))
    allow(runner).to receive(:verification_policy).and_return(policy)
    2.times { expect { service.call(attestation, policy: policy, build_result: result) }.to raise_error(RuntimeImages::ProviderError) }
    expect(attestation.reload.invalidated_at).to be_nil
  end
  it "recovers an abandoned newer verification attempt" do
    now = Time.current
    attestation
    abandoned = image.runtime_image_verification_attempts.create!(number: 2, image_digest: image.digest, state: "running", policy_snapshot: policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy), started_at: now - 2.hours)
    allow(orchestrator).to receive(:verify).and_return(:replacement)
    expect(service.call(attestation, policy: policy, now: now)).to eq(:replacement)
    expect(abandoned.reload).to have_attributes(state: "blocked", failure_code: "verification_interrupted")
  end
end
