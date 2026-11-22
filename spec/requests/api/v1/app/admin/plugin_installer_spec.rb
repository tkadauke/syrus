require "rails_helper"

RSpec.describe "API: plugin installer", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:release) do
    PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0, uploaded_by: admin)
  end

  it "requires an administrator" do
    get "/api/v1/app/admin/plugin_installer"
    expect(response).to have_http_status(:unauthorized)

    sign_in_as(Factories.user(admin: false))
    get "/api/v1/app/admin/plugin_installer"
    expect(response).to have_http_status(:forbidden)

    [
      [ "/api/v1/app/admin/plugin_installer/stage", { archive: "invalid" } ],
      [ "/api/v1/app/admin/plugin_installer/stage_remove", { name: "weather" } ],
      [ "/api/v1/app/admin/plugin_installer/stage_release", { name: "weather", version: "1.0.0" } ],
      [ "/api/v1/app/admin/plugin_installer/changes/1/confirm", {} ],
      [ "/api/v1/app/admin/plugin_installer/lockfile", { lockfile: "invalid" } ]
    ].each do |path, params|
      post path, params: params
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "manages configured registries but only disables the canonical and keeps environment sources read-only" do
    sign_in_as(admin)
    allow(SsrfGuard).to receive(:safe_host?).and_return(true)
    post "/api/v1/app/admin/plugin_installer/registries", params: { name: "partners", url: "https://partners.example.test" }
    expect(response).to have_http_status(:created)
    registry = PluginRegistry.find_by!(name: "partners")

    patch "/api/v1/app/admin/plugin_installer/registries/#{registry.id}", params: { enabled: false }
    expect(response).to have_http_status(:ok)
    expect(registry.reload).not_to be_enabled

    canonical = PluginRegistry.ensure_canonical!
    delete "/api/v1/app/admin/plugin_installer/registries/#{canonical.id}"
    expect(response).to have_http_status(:unprocessable_content)

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_PLUGIN_REGISTRY_URL").and_return("https://legacy.example.test")
    get "/api/v1/app/admin/plugin_installer/registries"
    expect(JSON.parse(response.body).fetch("registries")).to include(include("url" => "https://legacy.example.test", "read_only" => true))
  end

  it "stages a stored release for rollback" do
    sign_in_as(admin)
    PluginChange.create!(plugin_name: "weather", action: "install", plugin_release: release,
      capability_manifest: { "routes" => [ "/weather" ] }, status: "confirmed", staged_by: admin,
      confirmed_by: admin, confirmed_at: Time.current)

    post "/api/v1/app/admin/plugin_installer/stage_release", params: { name: "weather", version: "1.0.0" }

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to include("name" => "weather", "version" => "1.0.0",
      "capability_manifest" => { "routes" => [ "/weather" ] })
  end

  it "fetches and stages a registry release by name and version" do
    sign_in_as(admin)
    package = PluginRegistryPackageFetcher::Package.new(archive: StringIO.new("package"), signature: "signature",
      name: "weather", version: "2.0.0")
    allow_any_instance_of(PluginRegistryPackageFetcher).to receive(:fetch).with(name: "weather", version: "2.0.0").and_return(package)
    manifest = { "name" => "weather", "version" => "2.0.0", "routes" => [ "/weather" ] }
    allow_any_instance_of(Syrus::PluginPackage::Validator).to receive(:call).and_return(
      Syrus::PluginPackage::Validator::Result.new(valid: true, errors: [], manifest:)
    )
    allow_any_instance_of(Syrus::PluginPackage::Verifier).to receive(:call).and_return(
      Syrus::PluginPackage::Verifier::Result.new(valid: true, trust_label: "verified", fingerprint: "a" * 64, errors: [])
    )
    allow(PluginArtifacts).to receive(:store!)

    post "/api/v1/app/admin/plugin_installer/stage_release", params: { name: "weather", version: "2.0.0" }

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to include("name" => "weather", "version" => "2.0.0", "source" => "registry")
    expect(PluginRelease.find_by!(name: "weather", version: "2.0.0")).to have_attributes(trust_label: "verified", source: "registry")
  end

  it "rejects a revoked release when confirmation would change desired state" do
    sign_in_as(admin)
    change = PluginChange.create!(plugin_name: "weather", action: "install", plugin_release: release,
      capability_manifest: {}, status: "pending", staged_by: admin)
    trust_store = instance_double(Syrus::PluginPackage::TrustStore, revoked?: true)
    allow(Syrus::PluginPackage::TrustStore).to receive(:cached).and_return(trust_store)

    post "/api/v1/app/admin/plugin_installer/changes/#{change.id}/confirm"

    expect(response).to have_http_status(:unprocessable_content)
    expect(PluginInstallation).not_to exist(plugin_name: "weather")
  end

  it "does not offer revoked stored releases for restoration" do
    sign_in_as(admin)
    trust_store = instance_double(Syrus::PluginPackage::TrustStore)
    allow(trust_store).to receive(:revoked?).with(release).and_return(true)
    allow(Syrus::PluginPackage::TrustStore).to receive(:cached).and_return(trust_store)

    get "/api/v1/app/admin/plugin_installer"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).fetch("available_releases")).to be_empty
  end

  it "does not change desired state until the staged install is confirmed" do
    sign_in_as(admin)
    change = PluginChange.create!(plugin_name: "weather", action: "install", plugin_release: release,
      capability_manifest: { "routes" => [ "/weather" ] }, status: "pending", staged_by: admin)

    get "/api/v1/app/admin/plugin_installer"
    expect(JSON.parse(response.body).fetch("pending_changes").sole.dig("capability_diff", "routes", "added")).to eq([ "/weather" ])
    expect(PluginInstallation).not_to exist(plugin_name: "weather")

    allow(PluginDesiredState::Publisher).to receive(:publish!)
    post "/api/v1/app/admin/plugin_installer/changes/#{change.id}/confirm"
    expect(response).to have_http_status(:ok)
    expect(PluginInstallation.find_by!(plugin_name: "weather").plugin_release).to eq(release)
    expect(JSON.parse(response.body)).to include("restart_required" => true)
  end

  it "stages and confirms removal instead of deleting immediately" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release)
    sign_in_as(admin)

    post "/api/v1/app/admin/plugin_installer/stage_remove", params: { name: "weather" }
    change_id = JSON.parse(response.body).fetch("id")
    expect(PluginInstallation).to exist(plugin_name: "weather")

    post "/api/v1/app/admin/plugin_installer/changes/#{change_id}/confirm"
    expect(PluginInstallation).not_to exist(plugin_name: "weather")
  end

  it "replaces an installed release only after an update is confirmed" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release)
    replacement = PluginRelease.create!(name: "weather", version: "2.0.0", content_digest: "b" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0, uploaded_by: admin)
    change = PluginChange.create!(plugin_name: "weather", action: "update", plugin_release: replacement,
      capability_manifest: {}, status: "pending", staged_by: admin)
    sign_in_as(admin)

    expect(PluginInstallation.find_by!(plugin_name: "weather").plugin_release).to eq(release)
    post "/api/v1/app/admin/plugin_installer/changes/#{change.id}/confirm"

    expect(response).to have_http_status(:ok)
    expect(PluginInstallation.find_by!(plugin_name: "weather").plugin_release).to eq(replacement)
  end

  it "rejects an invalid package without recording a release" do
    sign_in_as(admin)
    file = Rack::Test::UploadedFile.new(StringIO.new("not an archive"), "application/octet-stream", original_filename: "bad.tar.gz")
    post "/api/v1/app/admin/plugin_installer/stage", params: { archive: file }

    expect(response).to have_http_status(:unprocessable_content)
    expect(PluginRelease.count).to eq(0)
  end
end
