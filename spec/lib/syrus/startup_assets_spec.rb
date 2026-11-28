require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::StartupAssets do
  def with_build(manifest, files)
    Dir.mktmpdir("startup-assets") do |dir|
      root = Pathname.new(dir)
      root.join(".vite").mkpath
      root.join(".vite/manifest.json").write(manifest.to_json)
      files.each { |name, bytes| root.join(name).binwrite("x" * bytes) }
      yield root
    end
  end

  let(:manifest) do
    {
      "app/frontend/main.tsx" => { "file" => "spa-entry-main.digested.js", "isEntry" => true, "imports" => [ "_vendor" ], "dynamicImports" => [ "app/frontend/routes/Search.tsx" ] },
      "_vendor" => { "file" => "spa-vendor.digested.js", "css" => [ "spa-vendor.digested.css" ] },
      "app/frontend/routes/Search.tsx" => { "file" => "spa-Search.digested.js", "isDynamicEntry" => true }
    }
  end

  it "sizes the entry, its static imports and the shell's stylesheets, leaving lazy routes out" do
    files = { "spa-entry-main.digested.js" => 1200, "spa-vendor.digested.js" => 3400, "spa-vendor.digested.css" => 50, "spa-Search.digested.js" => 9999 }

    with_build(manifest, files) do |root|
      result = described_class.new(
        manifest_path: root.join(".vite/manifest.json"),
        builds_root: root,
        stylesheets: { "/assets/tailwind-74e6a7ef.css" => 700, "/assets/spa-vendor.digested.css" => 50 }
      ).result

      expect(result.assets).to eq(
        "/assets/spa-entry-main.digested.js" => 1200,
        "/assets/spa-vendor.digested.js" => 3400,
        "/assets/spa-vendor.digested.css" => 50,
        "/assets/tailwind-74e6a7ef.css" => 700
      )
      expect(result.total_bytes).to eq(5350)
      expect(result.as_json).to eq("total" => 5350, "assets" => result.assets)
    end
  end

  it "computes once per revision and build rather than on every render" do
    described_class.reset!
    allow(SyrusVersion).to receive(:current).and_return("rev-1")
    allow(described_class).to receive(:app_stylesheets).and_return({})
    allow(Rails.root).to receive(:join).and_call_original
    fake_manifest = instance_double(Pathname, file?: true, mtime: Time.at(100))
    allow(Rails.root).to receive(:join).with(Syrus::ViteEntrypoint::MANIFEST_PATH).and_return(fake_manifest)
    first = described_class::Result.new(assets: { "/assets/a.js" => 1 })
    second = described_class::Result.new(assets: { "/assets/b.js" => 2 })
    instances = [ instance_double(described_class, result: first), instance_double(described_class, result: second) ]
    allow(described_class).to receive(:new) { instances.shift }

    expect(described_class.current).to eq(first)
    expect(described_class.current).to eq(first)
    expect(described_class).to have_received(:new).once

    allow(SyrusVersion).to receive(:current).and_return("rev-2")
    expect(described_class.current).to eq(second)
  ensure
    described_class.reset!
  end

  it "gives up before compiling stylesheets when there is no build" do
    described_class.reset!
    allow(Rails.root).to receive(:join).and_call_original
    allow(Rails.root).to receive(:join).with(Syrus::ViteEntrypoint::MANIFEST_PATH).and_return(instance_double(Pathname, file?: false, to_s: "missing"))
    allow(described_class).to receive(:app_stylesheets)

    expect { described_class.current }.to raise_error(Syrus::ViteEntrypoint::Missing)
    expect(described_class).not_to have_received(:app_stylesheets)
  ensure
    described_class.reset!
  end

  it "lists the stylesheets the shell links with their served sizes" do
    stylesheets = described_class.app_stylesheets

    startup_css = stylesheets.keys.grep(%r{\A/assets/startup_diagnostics-[0-9a-f]{8,}\.css\z})
    expect(startup_css.size).to eq(1)
    expect(stylesheets.fetch(startup_css.first)).to eq(Rails.root.join("app/assets/stylesheets/startup_diagnostics.css").size)
  end
end
