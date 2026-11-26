require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Verifications::SupplyChainScanner do
  let(:image) { instance_double(RuntimeImage, digest: "sha256:#{"a" * 64}") }
  let(:built_images) { instance_double(RuntimeImages::BuiltImages) }
  let(:runner) { double("runner") }
  let(:scanner) { described_class.new(built_images: built_images, runner: runner) }

  it "generates an SBOM and a package-and-layer report with reproducible scanner identity" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("registry/image@sha256:digest")
    commands = []
    allow(runner).to receive(:call) do |argv|
      commands << argv
      payload = if argv.include?("version")
        { "Version" => "0.76.2", "VulnerabilityDB" => { "UpdatedAt" => "2026-11-26T12:00:00Z" } }
      elsif argv.include?("cyclonedx")
        { "bomFormat" => "CycloneDX" }
      else
        { "Results" => [] }
      end
      [ JSON.generate(payload), 0 ]
    end

    scan = scanner.call(image)

    expect(scan).to have_attributes(scanner_name: "trivy", scanner_version: "0.76.2",
                                    database_version: "2026-11-26T12:00:00Z")
    expect(commands.last).to include("--scanners", "vuln", "--list-all-pkgs", "registry/image@sha256:digest")
  end

  it "fails closed when the database identity is absent" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return([ JSON.generate("Version" => "0.76.2"), 0 ])

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /database version/)
  end

  it "reports a non-object scanner identity as unavailable" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return([ JSON.generate(nil), 0 ])

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /identity is not a JSON object/)
  end

  it "fails closed when syntactically valid scanner output is not usable SBOM evidence" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return(
      [ JSON.generate("Version" => "0.76.2", "VulnerabilityDB" => { "UpdatedAt" => "2026-11-26T12:00:00Z" }), 0 ],
      [ JSON.generate("bomFormat" => "not-cyclonedx"), 0 ],
      [ JSON.generate("Results" => []), 0 ]
    )

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /not CycloneDX/)
  end

  it "reports a non-object SBOM as unavailable scanner evidence" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return(
      [ JSON.generate("Version" => "0.76.2", "VulnerabilityDB" => { "UpdatedAt" => "2026-11-26T12:00:00Z" }), 0 ],
      [ JSON.generate(nil), 0 ],
      [ JSON.generate("Results" => []), 0 ]
    )

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /not CycloneDX/)
  end

  it "does not interpret a malformed vulnerability report as a clean scan" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return(
      [ JSON.generate("Version" => "0.76.2", "VulnerabilityDB" => { "UpdatedAt" => "2026-11-26T12:00:00Z" }), 0 ],
      [ JSON.generate("bomFormat" => "CycloneDX"), 0 ],
      [ JSON.generate("SchemaVersion" => 2), 0 ]
    )

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /no results collection/)
  end

  it "reports a non-object vulnerability report as unavailable scanner evidence" do
    allow(built_images).to receive(:acquire_for_verification).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return(
      [ JSON.generate("Version" => "0.76.2", "VulnerabilityDB" => { "UpdatedAt" => "2026-11-26T12:00:00Z" }), 0 ],
      [ JSON.generate("bomFormat" => "CycloneDX"), 0 ],
      [ JSON.generate([]), 0 ]
    )

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /no results collection/)
  end

  it "scans an unverified image through the digest-validating acquisition boundary" do
    provider = SyntheticRuntimeImageProvider.new(key: "scanner-boundary")
    RuntimeImages::Providers.register(provider)
    namespace = RuntimeImageNamespace.create!(name: "scanner/boundary", owner_kind: "repository", owner_ref: "1", provider_key: provider.key)
    service = RuntimeImages::Service.new(provider: provider)
    candidate = service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "revision", platform: "linux/amd64",
                                payload: "image", verification_state: "unverified")
    local = false
    engine = instance_double(RuntimeImages::WorkerCache::Engine)
    allow(engine).to receive(:pull) { local = true }
    allow(engine).to receive(:digests) { local ? [ candidate.digest ] : [] }
    allow(engine).to receive(:size_bytes).and_return(10)
    cache = RuntimeImages::WorkerCache.new(engine: engine, service: service, hostname: "scanner-worker")
    images = RuntimeImages::BuiltImages.new(service: service, engine: engine, cache: cache, provider_key: provider.key)
    real_scanner = described_class.new(built_images: images, runner: runner)
    allow(runner).to receive(:call) do |argv|
      payload = if argv.include?("version")
        { "Version" => "0.76.2", "VulnerabilityDB" => { "UpdatedAt" => "2026-11-26T12:00:00Z" } }
      elsif argv.include?("cyclonedx")
        { "bomFormat" => "CycloneDX" }
      else
        { "Results" => [] }
      end
      [ JSON.generate(payload), 0 ]
    end

    expect { images.acquire(candidate) }.to raise_error(RuntimeImages::NotPullable)
    expect(real_scanner.call(candidate).report).to eq("Results" => [])
    expect(engine).to have_received(:pull).with(candidate.locator, timeout: 600, auth: nil)
  ensure
    RuntimeImages::Providers.unregister("scanner-boundary")
  end
end
