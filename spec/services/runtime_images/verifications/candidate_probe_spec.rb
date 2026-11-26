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
  let(:metadata) { { "Os" => "linux", "Architecture" => "amd64", "Config" => { "User" => "10001:10001", "Labels" => {} } } }
  let(:conformance) { RuntimeImages::ConformanceProbe.expected_checks.to_h { |key| [ key, :ok ] } }

  def conformance_output(checks = conformance)
    checks.map { |key, outcome| "#{outcome} #{key}#{outcome == :fail ? ": rejected" : ""}" }.join("\n") + "\n"
  end

  def stub_probe(metadata_result: metadata, checks: conformance, smoke_status: 0)
    allow(built_images).to receive(:acquire).with(image).and_yield(image.locator)
    allow(runner).to receive(:call) do |argv|
      if argv.include?("inspect") then [ JSON.generate(metadata_result), 0 ]
      elsif argv.include?("/usr/local/bin/syrus-base-probe") then [ conformance_output(checks), checks.value?(:fail) ? 1 : 0 ]
      else [ "smoke output", smoke_status ]
      end
    end
    allow(RuntimeImages::RuntimeAbi).to receive(:validate_for_launch!).and_return(true)
  end

  it "probes OCI metadata, ABI, confinement, every provider, and smoke under strict no-network limits" do
    commands = []
    stub_probe
    allow(runner).to receive(:call) do |argv|
      commands << argv
      if argv.include?("inspect") then [ JSON.generate(metadata), 0 ]
      elsif argv.include?("/usr/local/bin/syrus-base-probe") then [ conformance_output, 0 ]
      else [ "smoke ok", 0 ]
      end
    end

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.keys).to eq(RuntimeImages::Verifications::CandidateSuite.check_keys)
    expect(results.values).to all(be_passed)
    smoke = commands.last
    expect(smoke.each_cons(2).to_a).to include([ "--pids-limit", "256" ], [ "--entrypoint", "/bin/sh" ])
    expect(smoke.each_cons(3).to_a).to include([ "/bin/sh", image.locator, "-lc" ])
    expect(smoke.each_cons(4).to_a).to include([ "--memory", "1g", "--cpus", "1" ])
    expect(smoke.last).to eq("syrus-environment-smoke-test")
    expect(smoke.grep(/secret|credential|token/i)).to be_empty
  end

  it "rejects an image whose recorded base is not the pinned approved digest" do
    image.provenance["base_images"] = [ { "digest" => "sha256:#{"9" * 64}", "pinned" => true } ]
    image.save!
    expect(built_images).not_to receive(:acquire)

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.fetch("base_ancestry")).to have_attributes(outcome: :failed, failure_class: "integrity", code: "base_ancestry_mismatch")
  end

  it "rejects incompatible OCI platform and root-user metadata" do
    stub_probe(metadata_result: metadata.merge("Architecture" => "arm64", "Config" => metadata.fetch("Config").merge("User" => "root")))

    result = probe.call(image: image, build_request_id: request.id).fetch("oci_metadata")

    expect(result).to have_attributes(outcome: :failed, failure_class: "integrity", code: "oci_metadata_invalid")
  end

  it "reports an incompatible runtime ABI" do
    stub_probe
    abi = RuntimeImages::RuntimeAbi::Result.new([ RuntimeImages::RuntimeAbi::Problem.new(code: "abi_mismatch", message: "wrong ABI") ])
    allow(RuntimeImages::RuntimeAbi).to receive(:validate_for_launch!).and_raise(RuntimeImages::RuntimeAbi::Incompatible.new(abi))

    result = probe.call(image: image, build_request_id: request.id).fetch("runtime_abi")

    expect(result).to have_attributes(outcome: :failed, failure_class: "integrity", code: "abi_mismatch")
  end

  it "reports a failed confinement check" do
    checks = conformance.merge(RuntimeImages::ConformanceProbe::CONFINEMENT_CHECKS.first => :fail)
    stub_probe(checks: checks)

    result = probe.call(image: image, build_request_id: request.id).fetch("confinement")

    expect(result).to have_attributes(outcome: :failed, failure_class: "integrity", code: "confinement_failed")
  end

  it "reports a failed provider probe" do
    provider = RuntimeImages::RuntimeAbi.providers.keys.first
    stub_probe(checks: conformance.merge("provider-#{provider}" => :fail))

    result = probe.call(image: image, build_request_id: request.id).fetch("provider_#{provider}")

    expect(result).to have_attributes(outcome: :failed, failure_class: "integrity", code: "provider_probe_failed")
  end

  it "reports a failed smoke test" do
    stub_probe(smoke_status: 1)

    result = probe.call(image: image, build_request_id: request.id).fetch("smoke_test")

    expect(result).to have_attributes(outcome: :failed, failure_class: "policy", code: "smoke_test_failed")
  end

  it "reports an unavailable probe when image inspection fails" do
    allow(built_images).to receive(:acquire).with(image).and_yield(image.locator)
    allow(runner).to receive(:call).and_return([ "inspect failed", 1 ])

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.values).to all(have_attributes(failure_class: "infrastructure", code: "candidate_probe_unavailable"))
  end

  it "reports an unavailable probe when image inspection returns malformed JSON" do
    allow(built_images).to receive(:acquire).with(image).and_yield(image.locator)
    allow(runner).to receive(:call).and_return([ "not json", 0 ])

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.values).to all(have_attributes(failure_class: "infrastructure", code: "candidate_probe_unavailable"))
  end

  it "reports an unavailable probe when execution times out" do
    allow(built_images).to receive(:acquire).with(image).and_raise(Timeout::Error)

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.values).to all(have_attributes(failure_class: "infrastructure", code: "candidate_probe_unavailable"))
  end

  it "fails closed when the probe command omits the pids limit" do
    allow(built_images).to receive(:acquire).with(image).and_yield(image.locator)
    allow(runner).to receive(:call).with([ "docker", "image", "inspect", "--format", "{{json .}}", image.locator ])
      .and_return([ JSON.generate(metadata), 0 ])
    allow(RuntimeImages::RuntimeAbi).to receive(:validate_for_launch!).and_return(true)
    allow(RuntimeImages::CoworkerBase).to receive(:probe_command).and_return([ "docker", "run", "--entrypoint", "/probe", image.locator ])

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.values).to all(have_attributes(failure_class: "infrastructure", code: "candidate_probe_unavailable"))
  end

  it "fails closed when the smoke command omits the entrypoint" do
    command = [ "docker", "run", "--pids-limit", "256", image.locator ]
    allow(RuntimeImages::CoworkerBase).to receive(:probe_command).and_return(command)
    stub_probe

    results = probe.call(image: image, build_request_id: request.id)

    expect(results.values).to all(have_attributes(failure_class: "infrastructure", code: "candidate_probe_unavailable"))
  end
end
