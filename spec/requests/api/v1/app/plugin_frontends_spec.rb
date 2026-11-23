require "rails_helper"
require "tmpdir"

RSpec.describe "API: external plugin frontends", type: :request do
  let(:user) { Factories.user }

  around do |example|
    Dir.mktmpdir("plugin-frontend") do |dir|
      @plugin_root = Pathname.new(dir)
      @plugin_root.join("dist").mkpath
      @plugin_root.join("dist/plugin.js").write("export const fixture = true\n")
      @plugin_root.join("dist/plugin.css").write(".fixture { color: red }\n")
      @plugin_root.join("app/frontend/i18n/locales/en").mkpath
      @plugin_root.join("app/frontend/i18n/locales/de").mkpath
      @plugin_root.join("app/frontend/i18n/locales/en/external_fixture.json").write('{"greeting":"Hello"}')
      @plugin_root.join("app/frontend/i18n/locales/de/external_fixture.json").write('{"greeting":"Hallo"}')
      example.run
    end
  end

  before do
    sign_in_as(user)
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest ])
    allow(Syrus::PluginRegistry).to receive(:health).and_return(double(healthy?: true))
  end

  def manifest(enabled: true, frontend: { bundle: "dist/plugin.js", css: "dist/plugin.css", i18n: [ "app/frontend/i18n/locales/*/*.json" ] })
    Syrus::Plugin::Manifest.new(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: "external_fixture",
      version: "1.0.0",
      provides: {},
      metadata: { frontend: frontend },
      enabled: enabled,
      plugin_root: @plugin_root.to_s
    )
  end

  it "advertises and serves declared locale files" do
    get api_v1_app_bootstrap_path
    frontend = JSON.parse(response.body).dig("app", "external_plugin_frontends", 0)
    german = frontend.fetch("locales").find { |entry| entry["locale"] == "de" }

    expect(german).to include("namespace" => "external_fixture")
    get german.fetch("url")
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(JSON.parse(response.body)).to eq("greeting" => "Hallo")
  end

  it "advertises content-hashed URLs and serves immutable JavaScript and CSS" do
    get api_v1_app_bootstrap_path
    frontend = JSON.parse(response.body).dig("app", "external_plugin_frontends", 0)

    expect(frontend).to include("name" => "external_fixture", "hash" => match(/\A[0-9a-f]{64}\z/))

    get frontend.fetch("bundle_url")
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/javascript")
    expect(response.headers["Cache-Control"]).to include("max-age=31536000", "immutable")
    expect(response.body).to include("fixture = true")

    get frontend.fetch("css_url")
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/css")
  end

  it "rejects stale hashes" do
    get "/api/v1/app/plugin_frontends/external_fixture/bundle?v=stale"
    expect(response).to have_http_status(:not_found)
  end

  it "does not serve disabled plugins" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest(enabled: false) ])
    get "/api/v1/app/plugin_frontends/external_fixture/bundle?v=anything"
    expect(response).to have_http_status(:not_found)
  end

  it "does not serve missing files" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest(frontend: { bundle: "dist/missing.js" }) ])
    get "/api/v1/app/plugin_frontends/external_fixture/bundle?v=anything"
    expect(response).to have_http_status(:not_found)
  end

  it "does not resolve manifest paths outside the plugin root" do
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest(frontend: { bundle: "../secret.js" }) ])
    get "/api/v1/app/plugin_frontends/external_fixture/bundle?v=anything"
    expect(response).to have_http_status(:not_found)
  end

  it "does not route traversal-shaped plugin names" do
    get "/api/v1/app/plugin_frontends/%2E%2E/bundle?v=anything"
    expect(response).to have_http_status(:not_found)
  end
end
