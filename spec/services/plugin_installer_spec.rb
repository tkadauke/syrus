require "rails_helper"

RSpec.describe PluginInstaller do
  it "preserves verified trust when an existing archive is staged again" do
    admin = Factories.user(admin: true)
    release = PluginRelease.create!(name: "weather", version: "1.2.3", content_digest: Digest::SHA256.hexdigest("package"),
      source: "upload", trust_label: "verified", size_bytes: 7, uploaded_by: admin, signature: "signature",
      publisher_key_fingerprint: "a" * 64)
    release.archive.attach(io: StringIO.new("package"), filename: "weather.archive", content_type: "application/octet-stream")
    manifest = { "name" => "weather", "version" => "1.2.3", "routes" => [ "/weather" ] }
    validation = Syrus::PluginPackage::Validator::Result.new(valid: true, errors: [], manifest:)
    verification = Syrus::PluginPackage::Verifier::Result.new(valid: true, trust_label: "verified", fingerprint: "a" * 64, errors: [])
    allow_any_instance_of(Syrus::PluginPackage::Validator).to receive(:call).and_return(validation)
    allow_any_instance_of(Syrus::PluginPackage::Verifier).to receive(:call).and_return(verification)
    allow(PluginArtifacts).to receive(:store!)

    described_class.new(actor: admin).stage_archive!(StringIO.new("package"), signature: "signature")

    expect(release.reload.trust_label).to eq("verified")
    expect(PluginArtifacts).not_to have_received(:store!)
  end

  it "stages a stored previous release with its recorded capability manifest" do
    admin = Factories.user(admin: true)
    release = PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)
    PluginChange.create!(plugin_name: "weather", action: "install", plugin_release: release,
      capability_manifest: { "routes" => [ "/weather" ] }, status: "confirmed", staged_by: admin,
      confirmed_by: admin, confirmed_at: Time.current)
    PluginChange.create!(plugin_name: "weather", action: "update", plugin_release: release,
      capability_manifest: {}, status: "superseded", staged_by: admin)

    change = described_class.new(actor: admin).stage_release!("weather", version: "1.0.0")

    expect(change).to have_attributes(plugin_release: release, capability_manifest: { "routes" => [ "/weather" ] })
  end

  it "fetches an unstored registry release through package validation and staging" do
    admin = Factories.user(admin: true)
    allow(SsrfGuard).to receive(:safe_host?).and_return(true)
    registry = PluginRegistry.ensure_environment!("https://partners.example.test")
    trust_store = Syrus::PluginPackage::TrustStore.new("publishers" => [])
    fetcher = instance_double(PluginRegistryPackageFetcher)
    package = PluginRegistryPackageFetcher::Package.new(archive: StringIO.new("package"), signature: "signature",
      name: "weather", version: "2.0.0", registry:, trust_store:)
    allow(fetcher).to receive(:fetch).with(name: "weather", version: "2.0.0").and_return(package)
    manifest = { "name" => "weather", "version" => "2.0.0", "routes" => [ "/weather" ] }
    validation = Syrus::PluginPackage::Validator::Result.new(valid: true, errors: [], manifest:)
    verification = Syrus::PluginPackage::Verifier::Result.new(valid: true, trust_label: "verified", fingerprint: "a" * 64, errors: [])
    allow_any_instance_of(Syrus::PluginPackage::Validator).to receive(:call).and_return(validation)
    verifier = instance_double(Syrus::PluginPackage::Verifier, call: verification)
    expect(Syrus::PluginPackage::Verifier).to receive(:new).with(hash_including(trust_store:)).and_return(verifier)
    allow(PluginArtifacts).to receive(:store!)

    change = described_class.new(actor: admin, registry_fetcher: fetcher).stage_release!("weather", version: "2.0.0")

    expect(change.plugin_release).to have_attributes(name: "weather", version: "2.0.0", source: "registry",
      trust_label: "verified", plugin_registry: registry)
    expect(registry).to be_read_only
    expect(change.capability_manifest).to eq("routes" => [ "/weather" ])
  end

  it "rejects a registry package whose validated identity differs from the index" do
    admin = Factories.user(admin: true)
    fetcher = instance_double(PluginRegistryPackageFetcher)
    package = PluginRegistryPackageFetcher::Package.new(archive: StringIO.new("package"), signature: "signature",
      name: "weather", version: "2.0.0")
    allow(fetcher).to receive(:fetch).and_return(package)
    validation = Syrus::PluginPackage::Validator::Result.new(valid: true, errors: [],
      manifest: { "name" => "other", "version" => "2.0.0" })
    allow_any_instance_of(Syrus::PluginPackage::Validator).to receive(:call).and_return(validation)

    expect { described_class.new(actor: admin, registry_fetcher: fetcher).stage_release!("weather", version: "2.0.0") }
      .to raise_error(described_class::Error, /name does not match/)
    expect(PluginRelease).not_to exist(name: "other")
  end

  it "applies canonical preference and explicit selection to stored registry collisions" do
    admin = Factories.user(admin: true)
    allow(SsrfGuard).to receive(:safe_host?).and_return(true)
    canonical = PluginRegistry.ensure_canonical!
    partner = PluginRegistry.create!(name: "partner", url: "https://partner.example.test")
    canonical_release = PluginRelease.create!(name: "acme_weather", version: "1.0.0", content_digest: "a" * 64,
      source: "registry", trust_label: "official", size_bytes: 1, plugin_registry: canonical)
    partner_release = PluginRelease.create!(name: "acme_weather", version: "1.0.0", content_digest: "b" * 64,
      source: "registry", trust_label: "verified", size_bytes: 1, plugin_registry: partner)
    allow(Syrus::PluginPackage::TrustStore).to receive(:for_release)
      .and_return(instance_double(Syrus::PluginPackage::TrustStore, revoked?: false))

    preferred = described_class.new(actor: admin).stage_release!("acme_weather", version: "1.0.0")
    explicit = described_class.new(actor: admin).stage_release!("acme_weather", version: "1.0.0", registry: "partner")

    expect(preferred.plugin_release).to eq(canonical_release)
    expect(explicit.plugin_release).to eq(partner_release)
  end

  it "requires explicit selection for stored non-canonical registry collisions" do
    admin = Factories.user(admin: true)
    allow(SsrfGuard).to receive(:safe_host?).and_return(true)
    %w[first second].each_with_index do |name, index|
      registry = PluginRegistry.create!(name:, url: "https://#{name}.example.test")
      PluginRelease.create!(name: "acme_weather", version: "1.0.0", content_digest: index.to_s * 64,
        source: "registry", trust_label: "verified", size_bytes: 1, plugin_registry: registry)
    end

    expect { described_class.new(actor: admin).stage_release!("acme_weather", version: "1.0.0") }
      .to raise_error(described_class::Error, /ambiguous/)
  end
end
