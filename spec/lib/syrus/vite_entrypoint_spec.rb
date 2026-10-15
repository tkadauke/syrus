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

  it "explains how to produce the manifest when the SPA has not been built" do
    with_manifest(nil) do |entrypoint|
      expect { entrypoint.file }.to raise_error(described_class::Missing, /npm run build/)
    end
  end

  it "refuses a manifest without exactly one entry" do
    with_manifest({ "_vendor" => { "file" => "spa-vendor-Zz9_ab-c.digested.js" } }.to_json) do |entrypoint|
      expect { entrypoint.file }.to raise_error(described_class::Missing, /0 entries/)
    end
  end
end
