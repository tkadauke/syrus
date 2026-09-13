require "rails_helper"

RSpec.describe "Plugin link declaration", :reset_plugin_registry do
  it "adds normalized plugin-provided links to the manifest" do
    definition = Syrus::PluginApi::Definition.new(
      name: "linked_plugin", namespace: Module.new, lib_dir: Rails.root.to_s
    )

    definition.link "Open linked plugin", "/linked", description: "Primary surface"
    definition.surface "Always visible", "/linked/help", kind: "secondary", enabled_only: false

    Syrus::PluginRegistry.register(**definition.manifest_arguments)

    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "linked_plugin" }
    expect(manifest.links).to contain_exactly(
      {
        label: "Open linked plugin",
        url: "/linked",
        kind: "primary",
        description: "Primary surface",
        enabled_only: true
      },
      {
        label: "Always visible",
        url: "/linked/help",
        kind: "secondary",
        enabled_only: false
      }
    )
  end
end
