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

    change = described_class.new(actor: admin).stage_release!("weather", version: "1.0.0")

    expect(change).to have_attributes(plugin_release: release, capability_manifest: { "routes" => [ "/weather" ] })
  end
end
