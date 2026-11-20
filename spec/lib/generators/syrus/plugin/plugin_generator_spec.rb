require "rails_helper"
require "generators/syrus/plugin/plugin_generator"

RSpec.describe Syrus::Plugin::PluginGenerator do
  around do |example|
    Dir.mktmpdir("syrus-plugin-generator") do |dir|
      @destination_root = dir
      example.run
    end
  end

  it "generates the complete tested baseline" do
    described_class.start([ "sample_plugin" ], destination_root: destination_root)

    gemspec = read("plugins/sample_plugin/sample_plugin.gemspec")
    manifest = read("plugins/sample_plugin/lib/sample_plugin.rb")
    expect(gemspec).to include('spec.name = "sample_plugin"', 'spec.metadata["requires_syrus"] = ">= 0.1.0"')
    expect(manifest).to include("extend Syrus::PluginApi", 'provides callbacks: "SamplePlugin::Callbacks"')
    expect(manifest).to include('frontend bundle: "dist/frontend/plugin.js"')
    expect(path("plugins/sample_plugin/spec/sample_plugin_spec.rb")).to exist
    expect(path("plugins/sample_plugin/.github/workflows/test.yml")).to exist
    locale_keys = %w[en de la].map do |locale|
      JSON.parse(read("plugins/sample_plugin/app/frontend/i18n/locales/#{locale}/sample_plugin.json")).keys
    end
    expect(locale_keys).to all(eq(%w[plugin admin]))
  end

  it "generates each optional surface only when requested" do
    described_class.start(
      [ "sample_plugin", "--frontend", "--model", "--cli", "--syrus-version", "v1.2.3" ],
      destination_root: destination_root
    )

    manifest = read("plugins/sample_plugin/lib/sample_plugin.rb")
    expect(manifest).to include('provides admin_page: "SamplePlugin::AdminPages"')
    expect(manifest).to include('handler: "SamplePlugin::Cli::Hello"')
    expect(read("plugins/sample_plugin/sample_plugin.gemspec")).to include('requires_syrus"] = ">= 1.2.3"')
    expect(path("plugins/sample_plugin/frontend/entry.tsx")).to exist
    expect(path("plugins/sample_plugin/app/models/sample_plugin/widget.rb")).to exist
    expect(path("plugins/sample_plugin/db/migrate/20200101000000_create_sample_plugin_widgets.rb")).to exist
    expect(path("plugins/sample_plugin/app/services/sample_plugin/cli/hello.rb")).to exist
  end

  private

  attr_reader :destination_root

  def path(relative)
    Pathname.new(destination_root).join(relative)
  end

  def read(relative)
    path(relative).read
  end
end
