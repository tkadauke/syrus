require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::Orchestrator do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "verify/widgets", owner_kind: "test", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:image) do
    service.publish(namespace: namespace, source_kind: "test", source_ref: "revision-1", source_digest: "sha256:#{"a" * 64}",
                    platform: "linux/amd64", payload: "image")
  end
  let(:registry) { RuntimeImages::Verifications::Registry.new }
  let(:orchestrator) { described_class.new(registry: registry, service: service) }

  def result(**attributes)
    RuntimeImages::Verifications::Result.new(**{ outcome: :passed, evidence_references: [ { "kind" => "report", "digest" => image.digest } ],
                                                  failure_class: nil, code: nil, message: nil }.merge(attributes))
  end

  it "runs required checks in policy order and makes the verified digest a candidate" do
    calls = []
    registry.register("sbom", ->(**) { calls << "sbom"; result })
    registry.register("vulnerability", ->(**) { calls << "vulnerability"; result })
    policy = { "version" => 7, "z_setting" => true, "checks" => [ { "key" => "sbom", "required" => true }, { "key" => "vulnerability", "required" => true } ] }

    attempt = orchestrator.verify(image, policy: policy)

    expect(attempt).to be_accepted
    expect(attempt.decision).to eq("candidate")
    expect(attempt.image_digest).to eq(image.digest)
    expect(attempt.policy_snapshot).to eq(policy)
    expect(attempt.policy_snapshot.keys).to eq(%w[checks version z_setting])
    expect(attempt.checks.pluck(:verifier_key, :state)).to eq([ [ "sbom", "passed" ], [ "vulnerability", "passed" ] ])
    expect(calls).to eq(%w[sbom vulnerability])
    expect(image.reload).to be_candidate
  end

  it "bounds retries when an attempt number keeps colliding" do
    allow(RuntimeImageVerificationAttempt).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    expect { orchestrator.verify(image) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(RuntimeImageVerificationAttempt).to have_received(:create!).exactly(described_class::ATTEMPT_NUMBER_RETRIES + 1).times
  end

  it "fails closed when a required verifier is unavailable" do
    attempt = orchestrator.verify(image, policy: { "checks" => [ { "key" => "secret_scan", "required" => true } ] })

    expect(attempt).to have_attributes(state: "blocked", decision: "blocked", failure_class: "infrastructure", failure_code: "verifier_unavailable")
    expect(attempt.checks.first).to have_attributes(state: "unavailable", evidence_references: [])
    expect(image.reload).not_to be_pullable
  end

  it "does not accept a policy with no required checks" do
    attempt = orchestrator.verify(image, policy: { "checks" => [] })

    expect(attempt).to have_attributes(state: "blocked", failure_code: "verifier_unavailable")
    expect(attempt.checks.first.verifier_key).to eq("policy_checks_missing")
  end

  it "fails closed when successful check evidence cannot be stored or referenced" do
    registry.register("packages", ->(**) { result(evidence_references: []) })

    attempt = orchestrator.verify(image, policy: { "checks" => [ { "key" => "packages", "required" => true } ] })

    expect(attempt).to have_attributes(state: "blocked", failure_class: "evidence", failure_code: "evidence_unavailable")
  end

  it "rejects policy findings and preserves them across re-verification" do
    registry.register("vulnerability", ->(**) { result(outcome: :failed, failure_class: "policy", code: "high_vulnerability", message: "High finding") })
    policy = { "checks" => [ { "key" => "vulnerability", "required" => true } ] }
    first = orchestrator.verify(image, policy: policy)

    registry.register("vulnerability", ->(**) { result })
    second = orchestrator.verify(image, policy: policy)

    expect(first.reload).to have_attributes(number: 1, state: "rejected", decision: "rejected", failure_code: "high_vulnerability")
    expect(second).to have_attributes(number: 2, state: "accepted", decision: "candidate")
    expect(image.reload).to be_pullable
  end
end
