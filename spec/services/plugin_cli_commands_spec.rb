require "rails_helper"

# DOC-44: plugin CLI command collisions fail deterministically. The Go CLI
# mounts catalog commands at their bare path, first entry wins, and the
# catalog is sorted by plugin name -- so a collision used to hand the path to
# whichever plugin sorted first and silently drop the other. Every command in
# a collision is now withheld from the catalog and reported in plugin health
# (formal/SyrusModel/CliCollisions.lean).
RSpec.describe PluginCliCommands, :reset_plugin_registry do
  around do |example|
    Syrus::PluginRegistry.reset!
    example.run
    Syrus::PluginRegistry.reset!
  end

  def register(name, *paths)
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
      name: name, version: "1.0.0",
      cli_commands: paths.map { |path| { path: path, summary: "Run #{path.join(' ')}", handler: "PluginCliFixture::Handler" } }
    )
  end

  def catalog_keys
    described_class.catalog.map { |command| "#{command.plugin}:#{command.key}" }
  end

  it "withholds both commands when two plugins declare the same path" do
    register("alpha", %w[docs list], %w[alpha only])
    register("beta", %w[docs list])

    expect(catalog_keys).to eq([ "alpha:alpha only" ])
  end

  it "withholds a command that is a prefix of another plugin's command, in either name order" do
    register("alpha", %w[docs])
    register("beta", %w[docs list])
    register("gamma", %w[mail send])
    register("delta", %w[mail])

    expect(catalog_keys).to eq([])
  end

  it "keeps a plugin's own nested commands, which never collide with each other" do
    register("alpha", %w[docs], %w[docs list])

    expect(catalog_keys).to eq([ "alpha:docs", "alpha:docs list" ])
  end

  it "does not let a disabled plugin's command take a path away" do
    register("alpha", %w[docs list])
    register("beta", %w[docs list])
    PluginRecord.find_by!(name: "beta").update!(enabled: false)

    expect(catalog_keys).to eq([ "alpha:docs list" ])
  end

  it "reports each collision as a health warning on both plugins, which stay healthy" do
    register("alpha", %w[docs list])
    register("beta", %w[docs])
    health = Syrus::PluginRegistry.health

    expect(health.status("alpha").state).to eq(:warning)
    expect(health.status("alpha").reasons).to include("CLI command `docs list` collides with beta's `docs`; neither is offered")
    expect(health.status("beta").reasons).to include("CLI command `docs` collides with alpha's `docs list`; neither is offered")
    expect(health.healthy?("alpha")).to be(true)
  end
end
