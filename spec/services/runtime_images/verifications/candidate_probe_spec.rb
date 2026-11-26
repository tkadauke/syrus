require "rails_helper"

RSpec.describe RuntimeImages::Verifications::CandidateProbe do
  let(:base_digest) { "sha256:#{"b" * 64}" }
  let(:namespace) { RuntimeImageNamespace.create!(name: "candidate/probe", owner_kind: "test", owner_ref: "1", provider_key: "synthetic") }
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{"a" * 64}", locator: "registry.test/image@sha256:#{"a" * 64}",
                         source_kind: "extension", source_ref: "one", source_digest: "sha256:#{"c" * 64}", platform: "linux/amd64",
                         provenance: { "recipe_digest" => "sha256:#{"d" * 64}", "base_images" => [ { "digest" => base_digest, "pinned" => true } ] },
                         verification_state: "unverified", availability: "available", published_at: Time.current)
  end
  let(:request) do
    RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, source_kind: "extension", source_ref: "one",
                                     source_digest: image.source_digest, source_manifest: {}, recipe_digest: "sha256:#{"d" * 64}",
                                     recipe: { "input_policy" => { "base_digest" => base_digest,
                                                                    "smoke_test" => "syrus-environment-smoke-test" } },
                                     platform: "linux/amd64", requester_kind: "test", requester_ref: "1", dedup_key: "probe", state: "queued")
  end
  let(:built_images) { double("built images") }
  let(:runner) { double("runner") }
  let(:probe) { described_class.new(built_images: built_images, runner: runner) }

  it "probes OCI metadata, ABI, confinement, every provider, and smoke under strict no-network limits" do
    allow(built_images).to receive(:acquire).with(image).and_yield(image.locator)
    metadata = { "Os" => "linux", "Architecture" => "amd64", "Config" => { "User" => "10001:10001", "Labels" => {} } }
    conformance = RuntimeImages::ConformanceProbe.expected_checks.map { |key| "ok #{key}" }.join("\n") + "\n"
    commands = []
    allow(runner).to receive(:call) do |argv|
      commands << argv
      if argv.include?("inspect") then [ JSON.generate(metadata), 0 ]
      elsif argv.include?("/usr/local/bin/syrus-base-probe") then [ conformance, 0 ]
      else [ "smoke ok", 0 ]
      end
    end
    allow(RuntimeImages::RuntimeAbi).to receive(:validate_for_launch!).and_return(true)

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.keys).to eq(RuntimeImages::Verifications::CandidateSuite.check_keys)
    expect(results.values).to all(be_passed)
    smoke = commands.last
    expect(smoke).to include("--read-only", "--network", "none", "--cap-drop", "ALL", "--pids-limit", "256",
                             "--memory", "1g", "--cpus", "1", "--entrypoint", "/bin/sh", "-lc",
                             "syrus-environment-smoke-test")
    expect(smoke.grep(/secret|credential|token/i)).to be_empty
  end

  it "rejects an image whose recorded base is not the pinned approved digest" do
    image.provenance["base_images"] = [ { "digest" => "sha256:#{"9" * 64}", "pinned" => true } ]
    image.save!
    expect(built_images).not_to receive(:acquire)

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.fetch("base_ancestry")).to have_attributes(outcome: :failed, failure_class: "integrity", code: "base_ancestry_mismatch")
  end
end
