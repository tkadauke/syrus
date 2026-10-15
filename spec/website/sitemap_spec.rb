# frozen_string_literal: true

require "json"
require "open3"
require "spec_helper"

RSpec.describe "website sitemap" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:sitemap_library) { File.join(repo_root, "website/lib/sitemap.ts") }
  let(:sitemap_route) { File.read(File.join(repo_root, "website/src/app/sitemap.ts")) }

  it "builds normalized, deduplicated URLs from static, plugin, and docs pages" do
    program = <<~JAVASCRIPT
      import { sitemapUrls } from #{sitemap_library.to_json};
      console.log(JSON.stringify(sitemapUrls(
        [{ href: "/plugins/terminal" }, { href: "/plugins/terminal/" }],
        [{ href: "/docs/android" }, { href: "/docs/deployment/macos-workers" }],
      )));
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3(
      "node",
      "--experimental-strip-types",
      "--input-type=module",
      "--eval",
      program,
    )

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to include(
      "https://syrus-ai.dev/",
      "https://syrus-ai.dev/control-plane/",
      "https://syrus-ai.dev/download/",
      "https://syrus-ai.dev/plugins/",
      "https://syrus-ai.dev/plugins/terminal/",
      "https://syrus-ai.dev/docs/android/",
      "https://syrus-ai.dev/docs/deployment/macos-workers/",
    )
    expect(JSON.parse(stdout).count("https://syrus-ai.dev/plugins/terminal/")).to eq(1)
  end

  it "generates the build-time route from the same page sources as static params" do
    expect(sitemap_route).to include("sitemapUrls(allPlugins(), allDocs())")
    expect(File).not_to exist(File.join(repo_root, "website/public/sitemap.xml"))
  end
end
