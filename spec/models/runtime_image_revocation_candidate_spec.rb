require "rails_helper"

RSpec.describe RuntimeImageRevocationCandidate do
  it "rejects a candidate whose attestation belongs to another digest" do
    namespace = RuntimeImageNamespace.create!(name: "candidate/widgets", owner_kind: "test", owner_ref: "1", provider_key: "synthetic")
    first = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{"a" * 64}", platform: "linux/amd64",
                                 source_kind: "test", source_ref: "one", provenance: {})
    second = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{"b" * 64}", platform: "linux/amd64",
                                  source_kind: "test", source_ref: "two", provenance: {})
    attempt = first.runtime_image_verification_attempts.create!(number: 1, image_digest: first.digest, state: "rejected",
      policy_snapshot: {}, policy_digest: "sha256:#{"c" * 64}", started_at: Time.current)
    attestation = attempt.create_attestation!(runtime_image: first, image_digest: first.digest,
      policy_digest: attempt.policy_digest, evidence_digest: "sha256:#{"d" * 64}", outcome: "rejected",
      issued_at: Time.current, expires_at: 1.day.from_now)

    candidate = described_class.new(runtime_image: second, prior_attestation: attestation,
      triggering_attestation: attestation, reason_code: "policy_changed", state: "pending", detected_at: Time.current)

    expect(candidate).not_to be_valid
    expect(candidate.errors[:runtime_image]).to be_present
  end
end
