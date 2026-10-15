require "rails_helper"
require "json"
require "open3"

RSpec.describe "Vite build config" do
  let(:config) do
    script = <<~JS
      import { loadConfigFromFile } from "vite";

      const result = await loadConfigFromFile(
        { command: "build", mode: "production" },
        "vite.config.ts",
        process.cwd(),
        "silent"
      );
      const output = result.config.build.rollupOptions.output;
      const manualChunks = output.manualChunks;

      const plugins = result.config.plugins.flat();
      const fontsPlugin = plugins.find((plugin) => plugin && plugin.name === "syrus-excalidraw-fonts");
      const fontsConfig = await fontsPlugin.config();

      console.log(JSON.stringify({
        base: result.config.base,
        manifest: result.config.build.manifest,
        excalidrawAssetPath: fontsConfig.define.__EXCALIDRAW_ASSET_PATH__,
        entryFileNames: output.entryFileNames,
        chunkFileNames: output.chunkFileNames,
        assetFileNames: output.assetFileNames,
        nonVendor: manualChunks("/repo/app/frontend/main.tsx") ?? null,
        react: manualChunks("/repo/node_modules/react/index.js"),
        tanstack: manualChunks("/repo/node_modules/@tanstack/react-query/build/index.js"),
        visualization: manualChunks("/repo/node_modules/d3-scale/src/index.js"),
        fallbackVendor: manualChunks("/repo/node_modules/lodash-es/lodash.js"),
        windowsReact: manualChunks("C:\\\\repo\\\\node_modules\\\\react-dom\\\\index.js")
      }));
    JS

    stdout, stderr, status = Open3.capture3(
      { "NODE_ENV" => "test" },
      "node",
      "--input-type=module",
      "-e",
      script,
      chdir: Rails.root.to_s
    )

    raise "failed to load Vite config: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "content-hashes the entry like every chunk and records it in the build manifest" do
    expect(config.fetch("base")).to eq("/assets/")
    expect(config.fetch("manifest")).to be(true)
    expect(config.fetch("entryFileNames")).to eq("spa-entry-[hash].digested.js")
    expect(config.fetch("chunkFileNames")).to eq("spa-[name]-[hash].digested.js")
    expect(config.fetch("assetFileNames")).to eq("spa-[name]-[hash].digested[extname]")
  end

  # Regression: `spa.digested.js` carried the `.digested` marker but no
  # `-<hash>`, so Propshaft published it as `spa.digested-<sha>.js` and every
  # chunk importing `./spa.digested.js` got the HTML shell. Vite's import
  # graph is only valid if Propshaft serves each file under the exact name
  # Vite wrote. Vite hashes are base64url, so they may contain `-` and `_`.
  it "names every Vite output so Propshaft publishes it unchanged" do
    %w[entryFileNames chunkFileNames assetFileNames].each do |key|
      [ "Ab-_9xYz", "DuQfn8Z1", "-_-_-_-_" ].each do |hash|
        logical_path = config.fetch(key)
          .gsub("[name]", "INSIGHT.InsightPreviewCard")
          .gsub("[hash]", hash)
          .gsub("[extname]", ".css")
        asset = Propshaft::Asset.new(Pathname.new(logical_path), logical_path: logical_path, load_path: Rails.application.assets.load_path)

        expect(asset.digested_path.to_s).to eq(logical_path), "#{key} with hash #{hash}: Propshaft would publish #{logical_path} as #{asset.digested_path}"
      end
    end
  end

  it "points Excalidraw at self-hosted fonts instead of the CDN the CSP blocks" do
    version = JSON.parse(Rails.root.join("node_modules/@excalidraw/excalidraw/package.json").read).fetch("version")

    expect(config.fetch("excalidrawAssetPath")).to eq(JSON.generate("/excalidraw-assets/#{version}/"))
  end

  it "splits heavyweight dependencies out of the startup bundle" do
    expect(config).to include(
      "nonVendor" => nil,
      "react" => "vendor-react",
      "tanstack" => "vendor-query",
      "visualization" => "vendor-visualization",
      "fallbackVendor" => "vendor",
      "windowsReact" => "vendor-react"
    )
  end
end
