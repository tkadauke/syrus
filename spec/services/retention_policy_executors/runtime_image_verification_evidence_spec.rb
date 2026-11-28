require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RetentionPolicyExecutors::RuntimeImageVerificationEvidence do
  it "purges restricted reports while retaining safe summaries and digests" do
    RetentionPolicySetting.for(RetentionPolicyRegistry.fetch(:runtime_image_verification_evidence)).update!(retention_seconds: 90.days.to_i)
    provider = SyntheticRuntimeImageProvider.new
    namespace = RuntimeImageNamespace.create!(name: "retention/spec", owner_kind: "test", owner_ref: "1", provider_key: provider.key)
    image = RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image")
    attempt = image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: {}, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest({}), started_at: 100.days.ago, finished_at: 100.days.ago)
    evidence = attempt.create_policy_evidence!(image_digest: image.digest, safe_summary: { "finding_count" => 1 },
      report_digest: image.digest, scanned_at: 100.days.ago)
    evidence.report.attach(io: StringIO.new("restricted"), filename: "policy.json", content_type: "application/json")
    attestation = attempt.create_attestation!(runtime_image: image, image_digest: image.digest, policy_digest: attempt.policy_digest,
      evidence_digest: image.digest, outcome: "accepted", safe_summary: { "outcome" => "accepted" },
      issued_at: 100.days.ago, expires_at: 99.days.ago)

    result = RetentionPolicyRegistry.fetch(:runtime_image_verification_evidence).executor.call

    expect(result.deleted_count).to eq(1)
    expect(attestation.reload).to have_attributes(safe_summary: { "outcome" => "accepted" }, evidence_digest: image.digest)
    expect(attestation.exact_evidence_purged_at).to be_present
    expect(evidence.reload.report).not_to be_attached
  end
end
