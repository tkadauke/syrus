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

      console.log(JSON.stringify({
        entryFileNames: output.entryFileNames,
        chunkFileNames: output.chunkFileNames,
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

  it "keeps the Rails SPA entrypoint logical while allowing hashed chunks" do
    expect(config.fetch("entryFileNames")).to eq("spa.js")
    expect(config.fetch("chunkFileNames")).to eq("spa-[name]-[hash].js")
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
