require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImageBuildEvidence do
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: SyntheticRuntimeImageProvider.new.key) }
  let(:source) { RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: "c" * 40) }
  let(:request) do
    RuntimeImages::Builds::Orchestrator.new.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64",
                                                  requester_kind: "t", requester_ref: "1")
  end

  it "emits a safe summary without log text, resolved addresses, or rule detail" do
    attempt = request.attempts.create!(number: 1, state: "failed", started_at: Time.current)
    evidence = described_class.create!(
      request: request, attempt: attempt, outcome: "failed", source_digest: request.source_digest, builder_version: "buildah 1",
      layer_digests: [ "sha256:#{"1" * 64}" ], log: "secret-ish text", log_bytes: 15, finished_at: Time.current,
      destinations: [ { "host" => "github.com", "address" => "140.82.1.1", "count" => 3 } ],
      policy_snapshot: [ { "host" => "github.com" } ], base_images: [ { "reference" => "alpine", "digest" => "sha256:#{"2" * 64}", "pinned" => false, "extra" => 1 } ]
    )

    summary = evidence.safe_summary
    expect(summary).to include("outcome" => "failed", "layer_count" => 1, "destination_count" => 3, "builder_version" => "buildah 1")
    expect(summary["base_images"]).to eq([ { "reference" => "alpine", "digest" => "sha256:#{"2" * 64}", "pinned" => false } ])
    expect(summary.to_json).not_to include("secret-ish", "140.82.1.1", "policy_snapshot")
  end

  it "allows one evidence record per attempt" do
    attempt = request.attempts.create!(number: 1, state: "failed", started_at: Time.current)
    attrs = { request: request, attempt: attempt, outcome: "failed", source_digest: request.source_digest, finished_at: Time.current }
    described_class.create!(**attrs)
    expect(described_class.new(**attrs)).not_to be_valid
  end
end
