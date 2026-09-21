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
    admin_pages = read("plugins/sample_plugin/app/services/sample_plugin/admin_pages.rb")

    expect(admin_pages).to include("include Syrus::Plugin::AdminPage")
    expect(manifest).to include('provides admin_page: "SamplePlugin::AdminPages"')
    expect(manifest).to include('"sample_plugin/AdminExample" => "app/frontend/routes/AdminExample.tsx"')
    expect(manifest).to include('i18n: [ "app/frontend/i18n/locales/*/sample_plugin.json" ]')
    en_locale = JSON.parse(read("plugins/sample_plugin/app/frontend/i18n/locales/en/sample_plugin.json"))
    de_locale = JSON.parse(read("plugins/sample_plugin/app/frontend/i18n/locales/de/sample_plugin.json"))
    la_locale = JSON.parse(read("plugins/sample_plugin/app/frontend/i18n/locales/la/sample_plugin.json"))

    expect(en_locale.dig("admin", "title")).to eq("Sample plugin")
    expect(de_locale.dig("admin", "title")).to eq("Sample plugin")
    expect(la_locale.dig("admin", "title")).to eq("Sample plugin")
    expect(en_locale.fetch("admin").keys).to include(
      "description",
      "panel_message",
      "settings_heading",
      "name_label",
      "default_name",
      "mode_label",
      "mode_observe",
      "mode_act",
      "save"
    )
    expect(de_locale.fetch("admin").keys).to match_array(en_locale.fetch("admin").keys)
    expect(la_locale.fetch("admin").keys).to match_array(en_locale.fetch("admin").keys)
    expect(component).to include('from "@app/components/ui"')
    expect(component).to include('import { useT } from "@app/hooks/useT"')
    expect(component).to include('const { t } = useT("sample_plugin")')
    expect(component).to include('<Page.Root aria-label={t("admin.title")}>')
    expect(component).to include('<PageHeading>{t("admin.title")}</PageHeading>')
    expect(component).to include("<Page.Root ")
    expect(component).to include("<Card>")
    expect(component).to include("<Form.Field>")
    expect(component).to include('<Form.Label htmlFor="sample_plugin-name">{t("admin.name_label")}</Form.Label>')
    expect(component).to include('id="sample_plugin-name"')
    expect(component).to include('defaultValue={t("admin.default_name")}')
    expect(component).to include("<Form.Actions")
    expect(component).to include("<Input")
    expect(component).to include("<Select")
    expect(component).to include("<Button")
    expect(component).not_to include("A plugin-owned page using Syrus semantic UI primitives.")
    expect(component).not_to include("The plugin owns this message copy and any domain-specific visuals.")
    expect(component).not_to include("Example settings")
    expect(component).not_to include(">Name<")
    expect(component).not_to include(">Mode<")
    expect(component).not_to include(">Observe<")
    expect(component).not_to include(">Act<")
    expect(component).not_to include(">Save<")
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
