require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::Reevaluator do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "reevaluator/spec", owner_kind: "test", owner_ref: "1", provider_key: provider.key) }
  let(:image) { RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image") }
  let(:old_policy) { { "checks" => [ { "key" => "manifest", "required" => true } ], "version" => 1 } }
  let(:attempt) do
    image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: old_policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(old_policy),
      started_at: 1.hour.ago, finished_at: 1.hour.ago)
  end
  let(:attestation) do
    attempt.create_attestation!(runtime_image: image, image_digest: image.digest, policy_digest: attempt.policy_digest,
      evidence_digest: image.digest, outcome: "accepted", vulnerability_database_version: "db-1",
      issued_at: 1.hour.ago, expires_at: 1.day.from_now)
  end
  let(:orchestrator) { instance_double(RuntimeImages::Verifications::Orchestrator) }
  let(:build_runner) { instance_double(RuntimeImages::Builds::Runner) }
  subject(:reevaluator) { described_class.new(orchestrator: orchestrator, build_runner: build_runner) }

  it "detects required-check and vulnerability database changes" do
    changed = old_policy.deep_dup
    changed["checks"] << { "key" => "image_policy", "required" => true }

    expect(reevaluator.due?(attestation, policy: changed, database_version: "db-1")).to be(true)
    expect(reevaluator.due?(attestation, policy: old_policy, database_version: "db-2")).to be(true)
    expect(reevaluator.due?(attestation, policy: old_policy, database_version: "db-1")).to be(false)
  end

  it "passes the selected policy to the build-backed verification path" do
    policy = old_policy.merge("version" => 2)
    evidence = instance_double(RuntimeImageBuildEvidence, created_at: Time.current, id: 1)
    request = instance_double(RuntimeImageBuildRequest, evidences: [ evidence ])
    result = instance_double(RuntimeImageBuildResult, request: request)
    allow(build_runner).to receive(:verify_candidate).and_return(:replacement)

    expect(reevaluator.call(attestation, policy: policy, database_version: "db-1", build_result: result)).to eq(:replacement)
    expect(build_runner).to have_received(:verify_candidate).with(request, image, evidence, policy: policy)
  end

  it "fails closed while keeping a pre-verification failure eligible for retry" do
    image.update!(verification_state: "candidate")
    request = instance_double(RuntimeImageBuildRequest, evidences: [])
    result = instance_double(RuntimeImageBuildResult, request: request)

    2.times do
      expect {
        reevaluator.call(attestation, policy: old_policy, database_version: "db-2", build_result: result)
      }.to raise_error(RuntimeImages::ProviderError, "build evidence is unavailable for re-evaluation")
    end

    expect(image.reload.verification_state).to eq("unverified")
    expect(attestation.reload.invalidated_at).to be_nil
    expect(RuntimeImageVerificationAttestation.reevaluation_candidates).to include(attestation)
  end

  it "does not start a duplicate re-evaluation after a newer attempt exists" do
    attestation
    image.runtime_image_verification_attempts.create!(number: 2, image_digest: image.digest, state: "running",
      policy_snapshot: old_policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(old_policy),
      started_at: Time.current)
    image.update!(verification_state: "unverified")

    expect(orchestrator).not_to receive(:verify)
    expect(reevaluator.call(attestation, policy: old_policy, database_version: "db-2", build_result: nil)).to eq(attestation)
  end

  it "retries after a newer running attempt is abandoned" do
    now = Time.current
    attestation
    abandoned = image.runtime_image_verification_attempts.create!(number: 2, image_digest: image.digest, state: "running",
      policy_snapshot: old_policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(old_policy),
      started_at: now - described_class::STALE_ATTEMPT_AFTER - 1.second)
    image.update!(verification_state: "unverified")
    allow(orchestrator).to receive(:verify).and_return(:replacement)

    expect(reevaluator.call(attestation, policy: old_policy, database_version: "db-2", now: now, build_result: nil)).to eq(:replacement)
    expect(orchestrator).to have_received(:verify).with(image, policy: old_policy, now: now)
    expect(abandoned.reload).to have_attributes(state: "blocked", decision: "blocked",
      failure_class: "infrastructure", failure_code: "verification_interrupted")
    expect(abandoned.finished_at).to be_within(0.001).of(now)
  end

  it "uses the same effective build policy for comparison and verification" do
    request = instance_double(RuntimeImageBuildRequest)
    result = instance_double(RuntimeImageBuildResult, request: request)
    effective = old_policy.merge("checks" => old_policy["checks"] + [ { "key" => "image_policy", "required" => true } ])
    allow(build_runner).to receive(:verification_policy).with(request, base_policy: old_policy).and_return(effective)
    RuntimeImageVerificationAttestation.where(id: attestation.id)
      .update_all(policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(effective))
    attestation.reload

    expect(reevaluator.due?(attestation, policy: old_policy, database_version: "db-1", build_result: result)).to be(false)
  end
end
