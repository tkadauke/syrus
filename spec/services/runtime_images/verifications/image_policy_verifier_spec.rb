require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::ImagePolicyVerifier do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "policy/widgets", owner_kind: "test", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:image) do
    service.publish(namespace: namespace, source_kind: "test", source_ref: "revision", platform: "linux/amd64", payload: "image")
  end
  let(:request) do
    RuntimeImages::Builds::Orchestrator.new.submit(
      namespace: namespace, source: RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "repo", revision: "a" * 40),
      recipe: {}, platform: "linux/amd64", requester_kind: "test", requester_ref: "1"
    )
  end
  let(:attempt) do
    RuntimeImageVerificationAttempt.create!(runtime_image: image, number: 1, image_digest: image.digest, state: "running",
      policy_snapshot: {}, policy_digest: "sha256:" + ("b" * 64), started_at: Time.current)
  end
  let(:evidence) { RuntimeImages::Builds::Evidence.new }
  let(:scanner) { instance_double(RuntimeImages::Verifications::ImagePolicyScanner) }
  let(:verifier) { described_class.new(scanner: scanner) }
  let(:policy) { RuntimeImages::Verifications::Orchestrator::DEFAULT_POLICY }

  before { evidence.record_network(RuntimeImages::BuildNetwork::Policy.new([]), "destinations" => []) }

  it "accepts bounded non-root metadata and retains a restricted report" do
    allow(scanner).to receive(:call).and_return(report({
      "Size" => 100, "RootFS" => { "Layers" => [ "sha256:layer" ] },
      "Config" => { "User" => "1000:1000", "Entrypoint" => nil, "Cmd" => [ "/bin/bash" ], "Labels" => {} }
    }))

    result = verifier.call(image: image, policy: policy, context: context, attempt: attempt)

    expect(result).to be_passed
    expect(attempt.reload.policy_evidence.safe_summary).to eq("finding_count" => 0, "codes" => {})
    expect(attempt.policy_evidence.report).to be_attached
  end

  it "redacts secret details while rejecting secrets and structural policy violations" do
    secret = { "RuleID" => "private-key", "Match" => "super-secret-value", "StartLine" => 9 }
    allow(scanner).to receive(:call).and_return(report({
      "Size" => policy.dig("image", "max_bytes") + 1,
      "RootFS" => { "Layers" => Array.new(policy.dig("image", "max_layers") + 1, "sha256:layer") },
      "Config" => { "User" => "root", "Entrypoint" => [ "/bin/sh" ],
                    "Labels" => { "io.syrus.requested-capabilities" => "ALL" } }
    }, secrets: { "Results" => [ { "Target" => "source", "Secrets" => [ secret ] } ] }))

    result = verifier.call(image: image, policy: policy, context: context, attempt: attempt)

    expect(result).not_to be_passed
    expect(result.message).not_to include("super-secret-value", "private-key")
    expect(attempt.reload.policy_evidence.safe_summary.fetch("codes")).to include(
      "secret_detected" => 1, "image_too_large" => 1, "too_many_layers" => 1,
      "invalid_user" => 1, "invalid_entrypoint" => 1, "forbidden_capability" => 1
    )
    expect(attempt.policy_evidence.report.download).to include("super-secret-value")
  end

  it "rejects a recorded destination absent from the administrator snapshot" do
    evidence.record_network(RuntimeImages::BuildNetwork::Policy.new([]),
                            "destinations" => [ { "host" => "packages.example", "port" => 443, "count" => 1 } ])
    allow(scanner).to receive(:call).and_return(report({
      "Size" => 100, "RootFS" => { "Layers" => [] },
      "Config" => { "User" => "1000", "Entrypoint" => nil, "Cmd" => [ "/bin/bash" ], "Labels" => {} }
    }))

    result = verifier.call(image: image, policy: policy, context: context, attempt: attempt)

    expect(result.code).to eq("build_destination_not_allowlisted")
  end

  def context = { build_request_id: request.id, build_evidence: evidence }

  def report(metadata, secrets: { "Results" => [] })
    RuntimeImages::Verifications::ImagePolicyScanner::Report.new(
      metadata: metadata, history: "history", secrets: secrets, scanned_at: Time.current
    )
  end
end
