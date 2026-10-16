module FixturePlugin
  extend Syrus::PluginApi

  syrus_plugin "fixture_plugin" do
    display_name "Fixture Plugin"
    category "language"
    icon_url: "/plugin-icons/fixture.svg"
  end
end
