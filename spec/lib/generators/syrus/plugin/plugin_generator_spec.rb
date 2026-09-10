require "rails_helper"
require "generators/syrus/plugin/plugin_generator"

RSpec.describe Syrus::Plugin::PluginGenerator do
  around do |example|
    Dir.mktmpdir("syrus-plugin-generator") do |dir|
      @destination_root = dir
      example.run
    end
  end

  it "generates a modern PluginApi skeleton by default" do
    described_class.start([ "sample_plugin" ], destination_root: destination_root)

    expect(read("plugins/sample_plugin/sample_plugin.gemspec")).to eq(<<~RUBY)
      require_relative "../../lib/syrus/plugin_gemspec"

      Syrus.plugin_gemspec(__FILE__)
    RUBY
    expect(read("plugins/sample_plugin/lib/sample_plugin.rb")).to include("extend Syrus::PluginApi")
    expect(read("plugins/sample_plugin/lib/sample_plugin.rb")).to include('syrus_plugin "sample_plugin"')
    expect(File).not_to exist(path("plugins/sample_plugin/lib/sample_plugin/engine.rb"))
    expect(File).not_to exist(path("plugins/sample_plugin/lib/sample_plugin/version.rb"))
  end

  it "generates a semantic UI admin-page example when requested" do
    described_class.start([ "sample_plugin", "--frontend" ], destination_root: destination_root)

    component = read("plugins/sample_plugin/app/frontend/routes/AdminExample.tsx")
    manifest = read("plugins/sample_plugin/lib/sample_plugin.rb")

    expect(manifest).to include('provides admin_page: "SamplePlugin::AdminPages"')
    expect(manifest).to include('"sample_plugin/AdminExample" => "app/frontend/routes/AdminExample.tsx"')
    expect(manifest).to include('i18n: [ "app/frontend/i18n/locales/*/sample_plugin.json" ]')
    expect(read("plugins/sample_plugin/app/frontend/i18n/locales/en/sample_plugin.json")).to include('"title": "Sample plugin"')
    expect(read("plugins/sample_plugin/app/frontend/i18n/locales/de/sample_plugin.json")).to include('"title": "Sample plugin"')
    expect(read("plugins/sample_plugin/app/frontend/i18n/locales/la/sample_plugin.json")).to include('"title": "Sample plugin"')
    expect(component).to include('from "@app/components/ui"')
    expect(component).to include("<PageHeading>Sample plugin</PageHeading>")
    expect(component).to include("<Page ")
    expect(component).to include("<Card>")
    expect(component).to include("<FormField>")
    expect(component).to include('<FormLabel htmlFor="sample_plugin-name">')
    expect(component).to include('id="sample_plugin-name"')
    expect(component).to include("<FormActions")
    expect(component).to include("<Input")
    expect(component).to include("<Select")
    expect(component).to include("<Button")
    expect(component).not_to include("<main")
    expect(component).not_to include("<label")
    expect(component).not_to include("rounded border border-gray")
    expect(component).not_to include("bg-white")
    expect(component).not_to include("dark:bg-gray")
  end

  private

  attr_reader :destination_root

  def path(relative)
    File.join(destination_root, relative)
  end

  def read(relative)
    File.read(path(relative))
  end
end
