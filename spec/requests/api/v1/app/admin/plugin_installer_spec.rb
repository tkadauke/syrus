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
