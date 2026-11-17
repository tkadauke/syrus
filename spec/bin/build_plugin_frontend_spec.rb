require "rails_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/build-plugin-frontend" do
  it "builds an ESM bundle with host dependencies externalized and emits manifest metadata" do
    Dir.mktmpdir("external-plugin") do |dir|
      plugin_dir = Pathname.new(dir).join("plugin")
      FileUtils.cp_r(Rails.root.join("spec/fixtures/external_frontend_plugin"), plugin_dir)

      output, status = Open3.capture2e(Rails.root.join("bin/build-plugin-frontend").to_s, plugin_dir.to_s, chdir: Rails.root.to_s)
      expect(status).to be_success, output

      bundle = plugin_dir.join("dist/frontend/plugin.js").read
      manifest = JSON.parse(plugin_dir.join("dist/frontend/manifest.json").read)
      expect(bundle).to include('from"react"').or include("from \"react\"")
      expect(bundle).to include('from"@syrus/plugin-sdk"').or include("from \"@syrus/plugin-sdk\"")
      expect(plugin_dir.join("dist/frontend/plugin.css")).to exist
      expect(manifest).to eq("frontend" => {
        "bundle" => "dist/frontend/plugin.js",
        "css" => "dist/frontend/plugin.css"
      })
    end
  end
end
