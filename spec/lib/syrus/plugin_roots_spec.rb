require "spec_helper"
require "tmpdir"
require_relative "../../../lib/syrus/plugin_roots"

RSpec.describe Syrus::PluginRoots do
  def make_plugin(root, name)
    root.join(name).mkpath
  end

  it "enumerates and resolves built-in plugins without an external root" do
    Dir.mktmpdir do |directory|
      app = Pathname.new(directory)
      make_plugin(app.join("plugins"), "alpha")
      roots = described_class.new(application_root: app, external_path: nil, synced_path: nil)

      expect(roots.roots).to eq([ app.join("plugins") ])
      expect(roots.plugin_directories.map { |path| path.basename.to_s }).to eq([ "alpha" ])
      expect(roots.resolve("alpha")).to eq(app.join("plugins/alpha"))
      expect(roots).to be_built_in(app.join("plugins/alpha"))
      expect(roots).not_to be_external(app.join("plugins/alpha"))
    end
  end

  it "enumerates built-in plugins before external plugins" do
    Dir.mktmpdir do |directory|
      app = Pathname.new(directory).join("app")
      external = Pathname.new(directory).join("external")
      make_plugin(app.join("plugins"), "alpha")
      make_plugin(external, "beta")
      roots = described_class.new(application_root: app, external_path: external, synced_path: nil)

      expect(roots.plugin_directories.map { |path| path.basename.to_s }).to eq(%w[alpha beta])
      expect(roots).to be_external(external.join("beta"))
    end
  end

  it "resolves a relocatable plugin by its declared manifest name" do
    Dir.mktmpdir do |directory|
      app = Pathname.new(directory).join("app")
      external = Pathname.new(directory).join("external")
      installed = make_plugin(external, "registry-package-123")
      installed.join("lib").mkpath
      installed.join("lib/registry_package.rb").write(<<~RUBY)
        module RegistryPackage
          extend Syrus::PluginApi
          syrus_plugin "weather-tools" do
            default_enabled true
            disableable true
            experimental false
            requires_syrus nil
          end
        end
      RUBY
      roots = described_class.new(application_root: app, external_path: external, synced_path: nil)

      expect(roots.resolve("weather-tools")).to eq(installed)
    end
  end

  it "preserves built-in precedence when resolving a declared manifest name" do
    Dir.mktmpdir do |directory|
      app = Pathname.new(directory).join("app")
      external = Pathname.new(directory).join("external")
      built_in = make_plugin(app.join("plugins"), "bundled-package")
      built_in.join("lib").mkpath
      built_in.join("lib/bundled_package.rb").write(<<~RUBY)
        syrus_plugin "shared-name" do
          default_enabled true
          disableable true
          experimental false
          requires_syrus nil
        end
      RUBY
      make_plugin(external, "shared-name")
      roots = described_class.new(application_root: app, external_path: external, synced_path: nil)

      expect(roots.resolve("shared-name")).to eq(built_in)
    end
  end

  it "keeps the built-in plugin and reports a duplicate external name" do
    Dir.mktmpdir do |directory|
      app = Pathname.new(directory).join("app")
      external = Pathname.new(directory).join("external")
      make_plugin(app.join("plugins"), "same")
      make_plugin(external, "same")
      roots = described_class.new(application_root: app, external_path: external, synced_path: nil)

      expect(roots.resolve("same")).to eq(app.join("plugins/same"))
      expect(roots.duplicate_names).to eq([ "same" ])
      expect(roots.problems.fetch(0).message).to include("exists in both plugin roots", "skipping")
    end
  end

  it "reports and ignores a missing external root" do
    Dir.mktmpdir do |directory|
      roots = described_class.new(application_root: directory, external_path: Pathname.new(directory).join("missing"), synced_path: nil)

      expect(roots.problems.fetch(0).code).to eq(:missing)
      expect(roots.plugin_directories).to be_empty
    end
  end

  it "reports and ignores a non-directory external path" do
    Dir.mktmpdir do |directory|
      file = Pathname.new(directory).join("plugin-file")
      file.write("not a directory")
      roots = described_class.new(application_root: directory, external_path: file, synced_path: nil)

      expect(roots.problems.fetch(0).code).to eq(:not_directory)
      expect(roots.plugin_directories).to be_empty
    end
  end
  it "loads synced plugins after hand-placed plugins and reports duplicate names" do
    Dir.mktmpdir do |directory|
      app = Pathname.new(directory).join("app")
      external = Pathname.new(directory).join("external")
      synced = Pathname.new(directory).join("synced")
      make_plugin(external, "weather")
      make_plugin(synced, "weather")
      make_plugin(synced, "calendar")

      roots = described_class.new(application_root: app, external_path: external, synced_path: synced)

      expect(roots.plugin_directories.map { |path| path.basename.to_s }).to eq(%w[weather calendar])
      expect(roots.resolve("weather")).to eq(external.join("weather"))
      expect(roots.duplicate_names).to eq([ "weather" ])
      expect(roots).to be_external(synced.join("calendar"))
    end
  end
end
