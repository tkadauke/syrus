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

    candidate = described_class.new(runtime_image: second, attempt: attempt, trigger_kind: "policy_changed",
                                    severity: "high", state: "open", reason: "safe summary", detected_at: Time.current)

    expect(candidate).not_to be_valid
    expect(candidate.errors[:attempt]).to be_present
  end
end
