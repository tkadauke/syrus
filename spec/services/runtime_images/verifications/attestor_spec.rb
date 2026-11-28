require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::Attestor do
  let(:image) do
    namespace = RuntimeImageNamespace.create!(name: "attestor/spec", owner_kind: "test", owner_ref: "1", provider_key: SyntheticRuntimeImageProvider.new.key)
    RuntimeImages::Service.new(provider: SyntheticRuntimeImageProvider.new).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image")
  end
  def attempt(number:, state:, failure_class: nil)
    image.runtime_image_verification_attempts.create!(number: number, image_digest: image.digest, state: state,
      decision: state == "accepted" ? "candidate" : state, failure_class: failure_class,
      failure_code: failure_class ? "high_vulnerability" : nil, policy_snapshot: {},
      policy_digest: RuntimeImages::Verifications::CanonicalJson.digest({}), started_at: Time.current, finished_at: Time.current)
  end
  it "binds safe evidence to the immutable digest and supersedes the prior attestation" do
    first = described_class.new.issue!(attempt(number: 1, state: "accepted"), current: true)
    second = described_class.new.issue!(attempt(number: 2, state: "accepted"), current: true)
    expect(first.reload).to have_attributes(invalidation_reason: "superseded")
    expect(second).to be_valid_at
    expect(second.evidence_digest).to match(RuntimeImage::DIGEST_FORMAT)
  end
  it "emits a revocation candidate when a later policy scan rejects an accepted image" do
    prior = described_class.new.issue!(attempt(number: 1, state: "accepted"), current: true)
    rejected = described_class.new.issue!(attempt(number: 2, state: "rejected", failure_class: "policy"), current: true)
    expect(RuntimeImageRevocationCandidate.last).to have_attributes(prior_attestation: prior, triggering_attestation: rejected, reason_code: "high_vulnerability")
  end
end
