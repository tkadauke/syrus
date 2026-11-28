require "rails_helper"

RSpec.describe RuntimeImages::RuntimeAbi do
  let(:source_digest) { "sha256:#{"a" * 64}" }
  let(:recipe_digest) { "sha256:#{"b" * 64}" }
  let(:attestation) { described_class.attest(source_digest: source_digest, recipe_digest: recipe_digest, build_request_id: 7) }
  let(:labels) { described_class.labels }
  let(:image) do
    instance_double(RuntimeImage, digest: "sha256:#{"c" * 64}", availability: "available", revoked_at: nil, source_digest: source_digest,
                                  provenance: { "recipe_digest" => recipe_digest, described_class::ATTESTATION_KEY => attestation })
  end

  def check(**overrides)
    described_class.validate_for_launch(**{ image: image, labels: labels, provider: "claude" }.merge(overrides))
  end

  it "ships a consistent definition" do
    expect(described_class.validate_definition).to eq([])
    expect(RuntimeImages::CoworkerBase.validate).to eq([])
  end

  it "covers the contracted ABI surface" do
    expect(described_class.contract.keys).to include("entrypoint", "providers", "filesystem", "mcp", "user", "environment", "min_confinement_policy")
    expect(described_class.contract.dig("filesystem", "scratch")).to include("path" => "/scratch", "required" => false, "availability" => "admin_enabled")
    expect(described_class.contract.dig("filesystem", "tmp", "path")).to eq("/tmp")
  end

  it "carries the contract in the Dockerfile labels" do
    dockerfile = RuntimeImages::CoworkerBase::DIRECTORY.join("Dockerfile").read
    described_class.labels.each { |name, value| expect(dockerfile).to include(%(#{name}="#{value}")) }
  end

  it "has a digest independent of key order" do
    expect(described_class.canonical("b" => 1, "a" => { "d" => 1, "c" => 2 })).to eq('{"a":{"c":2,"d":1},"b":1}')
  end

  describe "pre-launch validation" do
    it "applies the administrator-supported ABI window" do
      allow(described_class).to receive(:compatibility).and_return("min" => 1, "max" => 3)
      AppSetting.current.update!(runtime_environment_policy: {
        "base" => { "supported_abi_min" => 2, "supported_abi_max" => 2 }
      })

      expect(described_class.supported?(2)).to be(true)
      expect(described_class.supported?(1)).to be(false)
      expect(described_class.supported?(3)).to be(false)
    end

    it "accepts a signed, in-range, launchable image" do
      expect(check).to be_compatible
      expect(described_class.current_contract?(image, provider: "claude")).to be(true)
    end

    it "refuses an image without ABI labels" do
      result = check(labels: {})
      expect(result.codes).to include("abi_missing", "confinement_policy_missing", "contract_mismatch")
    end

    it "refuses an ABI outside the compatibility range" do
      stale = labels.merge("io.syrus.runtime-abi.version" => "99", "io.syrus.runtime-abi.compat-min" => "99", "io.syrus.runtime-abi.compat-max" => "99")
      expect(check(labels: stale).codes).to include("abi_unsupported", "abi_range_excludes_syrus")
    end

    it "refuses an image requiring a newer confinement policy than the worker enforces" do
      expect(check(confinement_policy: 0).codes).to eq([ "confinement_policy_too_old" ])
    end

    it "refuses an unknown provider" do
      expect(check(provider: "nope").codes).to eq([ "provider_unsupported" ])
    end

    it "refuses revoked or unavailable images" do
      allow(image).to receive(:availability).and_return("revoked")
      expect(check.codes).to include("image_not_launchable")
    end

    it "refuses unsigned provenance and tampered signatures" do
      allow(image).to receive(:provenance).and_return({ "recipe_digest" => recipe_digest })
      expect(check.codes).to include("provenance_unsigned")

      forged = attestation.deep_dup.tap { |a| a["payload"]["contract_digest"] = "sha256:#{"0" * 64}" }
      allow(image).to receive(:provenance).and_return({ "recipe_digest" => recipe_digest, described_class::ATTESTATION_KEY => forged })
      expect(check.codes).to include("provenance_unsigned")
    end

    it "refuses a signature bound to a different source" do
      allow(image).to receive(:source_digest).and_return("sha256:#{"d" * 64}")
      expect(check.codes).to include("provenance_unsigned")
    end

    it "refuses labels that disagree with the signed contract" do
      expect(check(labels: labels.merge("io.syrus.runtime-abi.contract-digest" => "sha256:#{"e" * 64}")).codes).to eq([ "contract_mismatch" ])
    end

    it "refuses a previously signed provider contract after the current contract changes" do
      old_digest = "sha256:#{'0' * 64}"
      old_attestation = attestation.deep_dup
      old_attestation["payload"]["contract_digest"] = old_digest
      old_attestation["signature"] = described_class.send(:sign, old_attestation.fetch("payload"))
      allow(image).to receive(:provenance).and_return(
        { "recipe_digest" => recipe_digest, described_class::ATTESTATION_KEY => old_attestation }
      )

      stale_labels = labels.merge("io.syrus.runtime-abi.contract-digest" => old_digest)
      expect(check(labels: stale_labels).codes).to eq([ "contract_outdated" ])
      expect(described_class.current_contract?(image, provider: "claude")).to be(false)
      expect(described_class.outdated_contract?(image)).to be(true)
    end

    it "refuses widened compatibility or lowered confinement labels the signature does not cover" do
      { "compat-min" => "0", "compat-max" => "99", "min-confinement-policy" => "0", "version" => "2" }.each do |name, value|
        tampered = labels.merge("io.syrus.runtime-abi.#{name}" => value)
        expect(check(labels: tampered).codes).to include("label_mismatch"), "#{name} tampering was not detected"
      end
    end

    it "raises a typed error from the bang form" do
      expect { described_class.validate_for_launch!(image: image, labels: {}, provider: "claude") }.to raise_error(described_class::Incompatible, /abi_missing|ABI/)
    end
  end
end
