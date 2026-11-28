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
  # A revocation or supersession that committed while the claim waited on the
  # image lock is invisible to a plain re-read under MySQL's REPEATABLE READ:
  # the claim re-verified an attestation that was already invalidated (F153).
  it "does not re-verify an attestation invalidated while it waited, even when plain reads are stale" do
    attestation
    RuntimeImageVerificationAttestation.where(id: attestation.id).update_all(invalidated_at: Time.current, invalidation_reason: "revoked")
    stage_repeatable_read_snapshot!(RuntimeImageVerificationAttestation)
    allow(orchestrator).to receive(:verify)

    expect(service.call(attestation, policy: policy)).to eq(attestation)

    expect(orchestrator).not_to have_received(:verify)
  end

  # The newest evidence row of a request may belong to another image digest
  # (a later rebuild of the same request); re-evaluating with it would judge
  # this image by another image's build (F156).
  it "re-evaluates with the build evidence bound to the image's digest" do
    attestation
    own = instance_double(RuntimeImageBuildEvidence, image_digest: image.digest, created_at: 2.hours.ago, id: 1)
    other = instance_double(RuntimeImageBuildEvidence, image_digest: "sha256:#{"f" * 64}", created_at: 1.minute.ago, id: 2)
    request = instance_double(RuntimeImageBuildRequest, evidences: [ own, other ])
    result = instance_double(RuntimeImageBuildResult, request: request)
    allow(runner).to receive(:verification_policy).and_return(policy)
    allow(runner).to receive(:verify_candidate).and_return(:reverified)

    expect(service.call(attestation, policy: policy, build_result: result)).to eq(:reverified)
    expect(runner).to have_received(:verify_candidate).with(request, image, own, policy: policy)
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
