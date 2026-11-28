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

      expect(result.sizes).to eq(
        "/assets/spa-entry-main.digested.js" => 1200,
        "/assets/spa-vendor.digested.js" => 3400,
        "/assets/spa-vendor.digested.css" => 50,
        "/assets/tailwind-74e6a7ef.css" => 700
      )
      expect(result.lazy_chunks).to eq(
        "app/frontend/routes/Search.tsx" => { "file" => "spa-Search.digested.js", "size" => 9999 }
      )
      # No published variants: everything travels as it is.
      expect(result.for_request("gzip, deflate, br")).to eq(
        "total" => 5350,
        "budget" => { "kind" => "startup_gzip", "bytes" => 480_000 },
        "estimated" => false,
        "assets" => result.sizes.to_h { |path, size| [ path, { "size" => size, "wire" => size }.tap { |asset| asset["budget"] = size if path.end_with?(".js") } ] },
        "lazy_chunks" => result.lazy_chunks
      )
    end
  end

  describe "wire sizes" do
    def with_published(variants)
      Dir.mktmpdir("startup-assets-public") do |dir|
        published = Pathname.new(dir)
        variants.each { |name, bytes| published.join(name).binwrite("z" * bytes) }
        yield published
      end
    end

    def result_for(published)
      with_build(manifest, { "spa-entry-main.digested.js" => 4000, "spa-vendor.digested.js" => 2000, "spa-vendor.digested.css" => 100 }) do |root|
        return described_class.new(
          manifest_path: root.join(".vite/manifest.json"),
          builds_root: root,
          compressed_root: published
        ).result
      end
    end

    let(:variants) do
      {
        "spa-entry-main.digested.js.br" => 900, "spa-entry-main.digested.js.gz" => 1100,
        "spa-vendor.digested.js.gz" => 600,
        "spa-vendor.digested.css.br" => 30, "spa-vendor.digested.css.gz" => 40
      }
    end

    it "uses the Brotli variant when the browser takes it, else gzip, else the plain file" do
      with_published(variants) do |published|
        result = result_for(published)
        wire = ->(accept) { result.for_request(accept).fetch("assets").transform_values { |asset| asset.fetch("wire") } }

        expect(wire.call("gzip, deflate, br, zstd")).to eq(
          "/assets/spa-entry-main.digested.js" => 900,
          "/assets/spa-vendor.digested.js" => 600,
          "/assets/spa-vendor.digested.css" => 30
        )
        # Chrome sends no br over plain HTTP.
        expect(wire.call("gzip, deflate")).to eq(
          "/assets/spa-entry-main.digested.js" => 1100,
          "/assets/spa-vendor.digested.js" => 600,
          "/assets/spa-vendor.digested.css" => 40
        )
        expect(wire.call("identity")).to eq(
          "/assets/spa-entry-main.digested.js" => 4000,
          "/assets/spa-vendor.digested.js" => 2000,
          "/assets/spa-vendor.digested.css" => 100
        )
        expect(result.for_request("br;q=0, gzip").fetch("total")).to eq(1100 + 600 + 40)
        expect(result.for_request("gzip, br").fetch("estimated")).to be(false)
        expect(result.for_request("gzip, br").fetch("assets").fetch("/assets/spa-entry-main.digested.js")).to eq("size" => 4000, "wire" => 900, "budget" => 1100)
      end
    end

    it "assumes the smallest variant and marks the total as an estimate without an Accept-Encoding" do
      with_published(variants) do |published|
        meta = result_for(published).for_request(nil)

        expect(meta.fetch("estimated")).to be(true)
        expect(meta.fetch("total")).to eq(900 + 600 + 30)
      end
    end
  end

  it "computes once per revision and build rather than on every render" do
    described_class.reset!
    allow(SyrusVersion).to receive(:current).and_return("rev-1")
    allow(described_class).to receive(:app_stylesheets).and_return({})
    allow(Rails.root).to receive(:join).and_call_original
    fake_manifest = instance_double(Pathname, file?: true, mtime: Time.at(100))
    allow(Rails.root).to receive(:join).with(Syrus::ViteEntrypoint::MANIFEST_PATH).and_return(fake_manifest)
    first = described_class::Result.new(sizes: { "/assets/a.js" => 1 }, variants: {}, lazy_chunks: {})
    second = described_class::Result.new(sizes: { "/assets/b.js" => 2 }, variants: {}, lazy_chunks: {})
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
