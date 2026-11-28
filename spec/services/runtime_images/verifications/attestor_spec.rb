require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::Attestor do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "attestor/spec", owner_kind: "test", owner_ref: "1", provider_key: provider.key) }
  let(:image) { RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image") }

  def attempt(number:, state: "accepted", policy: { "checks" => [] }, failure_class: nil, failure_code: nil)
    image.runtime_image_verification_attempts.create!(
      number: number, image_digest: image.digest, state: state, decision: state == "accepted" ? "candidate" : state,
      policy_snapshot: policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy),
      failure_class: failure_class, failure_code: failure_code, started_at: Time.current, finished_at: Time.current
    )
  end

  it "binds immutable digests and rejects an attestation for another image" do
    record = attempt(number: 1)
    other = RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "2", platform: "linux/amd64", payload: "other")

    invalid = record.build_attestation(runtime_image: other, image_digest: image.digest, policy_digest: record.policy_digest,
      evidence_digest: image.digest, outcome: "accepted", issued_at: Time.current, expires_at: 1.day.from_now)

    expect(invalid).not_to be_valid
    expect(invalid.errors[:runtime_image]).to be_present
  end

  it "does not let a stale older attempt supersede a newer attestation" do
    older = attempt(number: 1)
    newer = attempt(number: 2)
    newer_attestation = described_class.new.issue!(newer, current: true)

    older_attestation = described_class.new.issue!(older, current: false)
    image.update!(verification_state: "candidate")

    expect(newer_attestation.reload).to be_valid_at
    expect(older_attestation).to have_attributes(invalidation_reason: "stale_attempt")
    expect(image.reload).to be_verified_candidate
  end
end
