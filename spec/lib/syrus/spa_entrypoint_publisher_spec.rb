require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::SpaEntrypointPublisher do
  it "publishes the Vite entrypoint at the stable browser-visible path" do
    Dir.mktmpdir("spa-entrypoint") do |dir|
      source = Pathname.new(dir).join("builds/spa.js")
      output = Pathname.new(dir).join("public/assets")
      source.dirname.mkpath
      source.write("import './spa-route-abc123.digested.js';")

      target = described_class.new(source_path: source, output_path: output).call

      expect(target).to eq(output.join("spa.js"))
      expect(target.read).to eq(source.read)
    end
  end

  it "fails the production build when Vite did not create its entrypoint" do
    Dir.mktmpdir("spa-entrypoint") do |dir|
      publisher = described_class.new(
        source_path: Pathname.new(dir).join("missing.js"),
        output_path: Pathname.new(dir).join("public/assets")
      )

      expect { publisher.call }.to raise_error(RuntimeError, /SPA entrypoint is missing/)
    end
  end
end
