module FixturePlugin
  extend Syrus::PluginApi

  syrus_plugin "fixture_plugin" do
    default_enabled true
    disableable true
    experimental false
    requires_syrus nil
    display_name "Fixture Plugin"
    category "language"
    icon_url: "/plugin-icons/fixture.svg"
  end
end
