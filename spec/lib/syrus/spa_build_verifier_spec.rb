require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::SpaBuildVerifier do
  def with_output(files, manifest: nil)
    Dir.mktmpdir("spa-build-verifier") do |dir|
      output = Pathname.new(dir)
      files.each { |name, content| output.join(name).write(content) }
      manifest_path = output.join("manifest.json")
      manifest_path.write(JSON.generate(manifest)) if manifest
      yield described_class.new(output_path: output, manifest_path: manifest && manifest_path)
    end
  end

  it "accepts locale sources emitted as separate hashed dynamic chunks" do
    manifest = {
      "app/frontend/i18n/locales/de/common.json" => {
        "file" => "spa-common-B8x_2ab.digested.js",
        "isDynamicEntry" => true
      },
      "plugins/git_history/app/frontend/i18n/locales/de/git_history.json" => {
        "file" => "spa-git_history-C9y_3cd.digested.js",
        "isDynamicEntry" => true
      }
    }

    with_output({}, manifest:) do |verifier|
      expect { verifier.call }.not_to raise_error
    end
  end

  it "rejects a manifest that folds locale sources into a non-dynamic asset" do
    manifest = {
      "app/frontend/i18n/locales/de/common.json" => {
        "file" => "spa-entry-B8x_2ab.digested.js"
      }
    }

    with_output({}, manifest:) do |verifier|
      expect { verifier.call }.to raise_error(described_class::BrokenReferences, /non-dynamic or unhashed entries/)
    end
  end

  it "accepts a bundle whose relative and preload references all exist" do
    files = {
      "spa-entry-AbC_12-x.digested.js" => %(const deps=["/assets/spa-Search-Zz9_ab-c.digested.js","/assets/spa-vendor-Q1w2e3r4.digested.css"];),
      "spa-Search-Zz9_ab-c.digested.js" => %(import{a as b}from"./spa-entry-AbC_12-x.digested.js";),
      "spa-vendor-Q1w2e3r4.digested.css" => "body{}"
    }

    with_output(files) do |verifier|
      expect { verifier.call }.not_to raise_error
    end
  end

  it "lists every chunk reference to a missing file" do
    files = {
      "spa-entry-AbC_12-x.digested.js" => %(import("/assets/spa-Gone-Zz9_ab-c.digested.js");m.f=["spa-Missing-Q1w2e3r4.digested.css"];),
      "spa-Search-Zz9_ab-c.digested.js" => %(import{a as b}from"./spa.digested.js";)
    }

    with_output(files) do |verifier|
      expect { verifier.call }.to raise_error(described_class::BrokenReferences) { |error|
        expect(error.message).to include("spa-entry-AbC_12-x.digested.js -> /assets/spa-Gone-Zz9_ab-c.digested.js")
        expect(error.message).to include("spa-entry-AbC_12-x.digested.js -> spa-Missing-Q1w2e3r4.digested.css")
        expect(error.message).to include("spa-Search-Zz9_ab-c.digested.js -> ./spa.digested.js")
      }
    end
  end

  # Excalidraw's vendor code names its fonts as `./fonts/...` and resolves
  # them against EXCALIDRAW_ASSET_PATH, not against the chunk.
  it "ignores non-module data paths that libraries resolve themselves" do
    with_output({ "spa-vendor-Q1w2e3r4.digested.js" => %(var a="./fonts/Virgil/Virgil-Regular.woff2";) }) do |verifier|
      expect { verifier.call }.not_to raise_error
    end
  end
end
