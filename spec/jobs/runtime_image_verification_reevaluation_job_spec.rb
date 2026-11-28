require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImageVerificationReevaluationJob do
  it "re-evaluates policy, database, or expiry candidates with one scanner identity lookup" do
    provider = SyntheticRuntimeImageProvider.new
    namespace = RuntimeImageNamespace.create!(name: "reevaluation/job", owner_kind: "test", owner_ref: "1", provider_key: provider.key)
    image = RuntimeImages::Service.new(provider: provider).publish(namespace: namespace, source_kind: "test", source_ref: "1", platform: "linux/amd64", payload: "image")
    policy = RuntimeImages::Verifications::Policy.current
    attempt = image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy), started_at: 2.days.ago, finished_at: 2.days.ago)
    expired = attempt.create_attestation!(runtime_image: image, image_digest: image.digest, policy_digest: attempt.policy_digest,
      evidence_digest: image.digest, outcome: "accepted", vulnerability_database_version: "db-1", issued_at: 2.days.ago, expires_at: 1.hour.ago)
    scanner = instance_double(RuntimeImages::Verifications::SupplyChainScanner, current_database_version: "db-2")
    reevaluator = instance_double(RuntimeImages::Verifications::Reevaluator, due?: true, call: nil)
    allow(RuntimeImages::Verifications::SupplyChainScanner).to receive(:new).and_return(scanner)
    allow(RuntimeImages::Verifications::Reevaluator).to receive(:new).and_return(reevaluator)

    described_class.perform_now

    expect(scanner).to have_received(:current_database_version).once
    expect(reevaluator).to have_received(:call).with(expired, policy: policy, database_version: "db-2", build_result: nil)
  end
end
