require "spec_helper"
require "tmpdir"
require_relative "../../lib/plugin_roots"

RSpec.describe PluginRoots do
  around do |example|
    Dir.mktmpdir("plugin-roots") do |directory|
      @application_root = Pathname.new(directory).join("app")
      @built_in = @application_root.join("plugins")
      @external = Pathname.new(directory).join("external")
      @built_in.mkpath
      example.run
    end
  end

  def roots(external_path: nil)
    described_class.new(application_root: @application_root, external_path:)
  end

  it "returns only the built-in root without external configuration" do
    expect(roots.roots).to eq([ @built_in ])
  end

  it "returns the built-in root before a configured external root" do
    @external.mkpath

    expect(roots(external_path: @external).roots).to eq([ @built_in, @external ])
  end

  it "skips an external duplicate, resolves the built-in plugin, and records the collision" do
    built_in_plugin = @built_in.join("weather").tap(&:mkpath)
    external_plugin = @external.join("weather").tap(&:mkpath)
    subject = roots(external_path: @external)

    expect(subject.plugin_directories).to eq([ built_in_plugin ])
    expect(subject.resolve("weather")).to eq(built_in_plugin)
    expect(subject.duplicates).to contain_exactly(
      have_attributes(name: "weather", built_in: built_in_plugin, skipped: external_plugin)
    )
  end

  it "ignores a missing external root" do
    expect(roots(external_path: @external).roots).to eq([ @built_in ])
  end

  it "ignores an external path that is not a directory" do
    @external.write("not a directory")

    expect(roots(external_path: @external).roots).to eq([ @built_in ])
  end

  it "identifies built-in and external directories" do
    built_in_plugin = @built_in.join("one").tap(&:mkpath)
    external_plugin = @external.join("two").tap(&:mkpath)
    subject = roots(external_path: @external)

    expect(subject.built_in?(built_in_plugin)).to be(true)
    expect(subject.external?(external_plugin)).to be(true)
    expect(subject.external?(built_in_plugin)).to be(false)
  end

  it "enumerates an external plugin and exposes its migration directory" do
    migration_dir = @external.join("weather/db/migrate").tap(&:mkpath)
    subject = roots(external_path: @external)

    expect(subject.plugin_directories).to include(@external.join("weather"))
    expect(subject.migration_directories).to include(migration_dir)
  end
end
