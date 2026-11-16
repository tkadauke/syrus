require "rails_helper"

RSpec.describe Syrus::Plugin::CliCommand, :reset_plugin_registry do
  def register(commands)
    Syrus::PluginRegistry.register(name: "command_fixture", version: "1.0.0", cli_commands: commands)
    Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "command_fixture" }
  end

  it "accepts a valid declaration" do
    manifest = register([ {
      path: "docs list", summary: "List documents", handler: "Docs::ListCommand",
      arguments: [ { name: "query", type: "string" } ],
      flags: [ { name: "limit", type: "integer", default: 20 } ]
    } ])

    expect(manifest.registration_errors).to be_empty
    expect(manifest.cli_commands.first.fetch("path")).to eq("docs list")
  end

  it "reports a missing handler through plugin health without crashing registration" do
    manifest = register([ { path: "docs list", summary: "List documents" } ])

    expect(manifest.registration_errors).to include(/missing handler/)
    expect(Syrus::PluginRegistry.health.status("command_fixture").state).to eq(:degraded)
  end

  it "reports duplicate command paths through plugin health" do
    command = { path: "docs list", summary: "List documents", handler: "Docs::ListCommand" }
    register([ command, command ])

    expect(Syrus::PluginRegistry.health.status("command_fixture").reasons).to include(/duplicate CLI command path/)
  end

  it "reports a bad flag type through plugin health" do
    register([ {
      path: "docs list", summary: "List documents", handler: "Docs::ListCommand",
      flags: [ { name: "limit", type: "float" } ]
    } ])

    expect(Syrus::PluginRegistry.health.status("command_fixture").reasons).to include(/bad type "float"/)
  end
end
