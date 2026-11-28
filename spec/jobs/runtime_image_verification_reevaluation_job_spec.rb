require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImageVerificationReevaluationJob do
  it "re-evaluates expired accepted attestations and leaves current ones alone" do
    provider = SyntheticRuntimeImageProvider.new
    namespace = RuntimeImageNamespace.create!(name: "reevaluation/jobs", owner_kind: "test", owner_ref: "1", provider_key: provider.key)
    image = RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image")
    attempt = image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: {}, policy_digest: "sha256:" + ("a" * 64), started_at: 2.days.ago, finished_at: 2.days.ago)
    expired = attempt.create_attestation!(runtime_image: image, image_digest: image.digest, policy_digest: attempt.policy_digest,
      evidence_digest: "sha256:" + ("b" * 64), outcome: "accepted", issued_at: 2.days.ago, expires_at: 1.hour.ago)
    reevaluator = instance_double(RuntimeImages::Verifications::Reevaluator, call: nil)
    allow(RuntimeImages::Verifications::Reevaluator).to receive(:new).and_return(reevaluator)

    described_class.perform_now

    expect(reevaluator).to have_received(:call).with(expired, policy: RuntimeImages::Verifications::Policy.current)
  end
end
