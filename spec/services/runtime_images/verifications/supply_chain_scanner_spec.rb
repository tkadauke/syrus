require "rails_helper"

RSpec.describe RuntimeImages::Verifications::SupplyChainScanner do
  let(:image) { instance_double(RuntimeImage, digest: "sha256:#{"a" * 64}") }
  let(:built_images) { instance_double(RuntimeImages::BuiltImages) }
  let(:runner) { double("runner") }
  let(:scanner) { described_class.new(built_images: built_images, runner: runner) }

  it "generates an SBOM and a package-and-layer report with reproducible scanner identity" do
    allow(built_images).to receive(:acquire).with(image).and_yield("registry/image@sha256:digest")
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
    allow(built_images).to receive(:acquire).with(image).and_yield("image")
    allow(runner).to receive(:call).and_return([ JSON.generate("Version" => "0.76.2"), 0 ])

    expect { scanner.call(image) }.to raise_error(RuntimeImages::ProviderError, /database version/)
  end
end
