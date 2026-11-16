# frozen_string_literal: true

require "rails_helper"

RSpec.describe Syrus::Plugin::CliCommand do
  def register(commands)
    Syrus::PluginRegistry.register(name: "command_fixture", version: "1.0.0", cli_commands: commands)
    Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "command_fixture" }
  end

  let(:valid_command) do
    {
      path: "docs list", summary: "List documents", handler: "CommandFixture::Handler",
      arguments: [ { name: "query", type: "string", required: true } ],
      flags: [ { name: "limit", type: "integer", default: 10 } ]
    }
  end

  it "accepts and normalizes a valid declaration" do
    manifest = register([ valid_command ])

    expect(manifest.validation_errors).to be_empty
    expect(manifest.cli_commands.first).to include("path" => "docs list", "handler" => "CommandFixture::Handler")
  end

  it "adds DSL command declarations to manifest arguments" do
    definition = Syrus::PluginApi::Definition.new(name: "dsl_fixture", namespace: Module.new, lib_dir: __dir__)
    definition.cli_command("docs list", summary: "List documents", handler: "CommandFixture::Handler")

    expect(definition.manifest_arguments.fetch(:cli_commands)).to contain_exactly(
      hash_including(path: "docs list", handler: "CommandFixture::Handler")
    )
  end

  it "coerces supported argument and flag values" do
    command = described_class.normalize(
      path: "docs list", summary: "List documents", handler: "CommandFixture::Handler",
      arguments: [ { name: "count", type: "integer", default: 2 } ],
      flags: [ { name: "tag", type: "repeatable_string" }, { name: "all", type: "boolean" } ]
    )

    expect(described_class.coerce(command, args: {}, flags: { tag: "one", all: "true" })).to eq(
      [ { "count" => 2 }, { "tag" => [ "one" ], "all" => true } ]
    )
  end

  it "reports a missing handler through plugin health without crashing registration" do
    manifest = register([ valid_command.except(:handler) ])

    expect(manifest.validation_errors.join).to include("missing handler")
    expect(Syrus::PluginRegistry.health.status("command_fixture").state).to eq(:degraded)
  end

  it "reports duplicate command paths through plugin health" do
    manifest = register([ valid_command, valid_command ])

    expect(manifest.validation_errors.join).to include("duplicate CLI command path")
  end

  it "reports a bad flag type through plugin health" do
    manifest = register([ valid_command.merge(flags: [ { name: "format", type: "mystery" } ]) ])

    expect(manifest.validation_errors.join).to include("bad flag type")
  end
end
