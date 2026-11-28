require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::ViteEntrypoint do
  def with_manifest(content)
    Dir.mktmpdir("vite-entrypoint") do |dir|
      path = Pathname.new(dir).join("manifest.json")
      path.write(content) unless content.nil?
      yield described_class.new(path)
    end
  end

  it "returns the content-hashed entry file the manifest names" do
    manifest = {
      "app/frontend/main.tsx" => { "file" => "spa-entry-AbC_12-x.digested.js", "isEntry" => true },
      "_vendor" => { "file" => "spa-vendor-Zz9_ab-c.digested.js" },
      "app/frontend/routes/Search.tsx" => { "file" => "spa-Search-Q1w2e3r4.digested.js", "isDynamicEntry" => true }
    }

    with_manifest(manifest.to_json) do |entrypoint|
      expect(entrypoint.file).to eq("spa-entry-AbC_12-x.digested.js")
    end
  end

  it "maps the public plugin host modules to their content-hashed entries" do
    sources = {
      "app/frontend/main.tsx" => { "file" => "spa-entry-main.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/react.ts" => { "file" => "react.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/reactJsxRuntime.ts" => { "file" => "jsx.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/reactDom.ts" => { "file" => "dom.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/reactDomClient.ts" => { "file" => "dom-client.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/reactQuery.ts" => { "file" => "query.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/i18next.ts" => { "file" => "i18next.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/reactI18next.ts" => { "file" => "react-i18next.digested.js", "isEntry" => true },
      "app/frontend/pluginHost/sdk.ts" => { "file" => "sdk.digested.js", "isEntry" => true }
    }

    with_manifest(sources.to_json) do |entrypoint|
      expect(entrypoint.plugin_import_map.fetch("imports")).to include(
        "react" => "/assets/react.digested.js",
        "react/jsx-runtime" => "/assets/jsx.digested.js",
        "@syrus/plugin-sdk" => "/assets/sdk.digested.js"
      )
    end
  end

  it "lists the entry, its static imports transitively, and their CSS as the startup files" do
    manifest = {
      "app/frontend/main.tsx" => { "file" => "spa-entry-main.digested.js", "isEntry" => true, "imports" => [ "_vendor", "_shared" ], "dynamicImports" => [ "app/frontend/routes/Search.tsx" ] },
      "_vendor" => { "file" => "spa-vendor.digested.js", "imports" => [ "_runtime" ] },
      "_shared" => { "file" => "spa-shared.digested.js", "imports" => [ "_runtime" ], "css" => [ "spa-shared.digested.css" ] },
      "_runtime" => { "file" => "spa-runtime.digested.js" },
      "app/frontend/routes/Search.tsx" => { "file" => "spa-Search.digested.js", "isDynamicEntry" => true, "imports" => [ "_vendor" ] }
    }

    with_manifest(manifest.to_json) do |entrypoint|
      expect(entrypoint.startup_files).to eq(%w[
        spa-entry-main.digested.js
        spa-vendor.digested.js
        spa-shared.digested.js
        spa-shared.digested.css
        spa-runtime.digested.js
      ])
    end
  end

  it "refuses a startup graph that imports a chunk the manifest does not list" do
    manifest = { "app/frontend/main.tsx" => { "file" => "spa-entry-main.digested.js", "imports" => [ "_gone" ] } }

    with_manifest(manifest.to_json) do |entrypoint|
      expect { entrypoint.startup_files }.to raise_error(described_class::Missing, /incomplete/)
    end
  end

  it "explains how to produce the manifest when the SPA has not been built" do
    with_manifest(nil) do |entrypoint|
      expect { entrypoint.file }.to raise_error(described_class::Missing, /npm run build/)
    end
  end

  it "refuses a manifest without the application entry" do
    with_manifest({ "_vendor" => { "file" => "spa-vendor-Zz9_ab-c.digested.js" } }.to_json) do |entrypoint|
      expect { entrypoint.file }.to raise_error(described_class::Missing, /does not list/)
    end
  end
end
