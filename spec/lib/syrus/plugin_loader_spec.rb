require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginLoader do
  def write_plugin(root, directory_name:, gem_name:, plugin_name: gem_name, dependencies: [], gem_dependencies: [], requires_syrus: nil)
    directory = root.join(directory_name)
    directory.join("lib").mkpath
    dependency_lines = ([ [ "rails", ">= 8.1" ] ] + gem_dependencies).map do |name, requirement|
      %(  spec.add_dependency #{name.inspect}, #{requirement.inspect})
    end.join("\n")
    directory.join("#{gem_name}.gemspec").write(<<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = #{gem_name.inspect}
        spec.version = "0.1.0"
        spec.summary = "fixture"
        spec.authors = [ "Spec" ]
        spec.files = []
        spec.metadata["requires_syrus"] = #{requires_syrus.inspect} if #{!requires_syrus.nil?}
        #{dependency_lines}
      end
    RUBY
    dependency_declaration = dependencies.any? ? "depends_on #{dependencies.inspect}" : ""
    directory.join("lib/#{gem_name}.rb").write(<<~RUBY)
      module ExternalLoaderFixture
        extend Syrus::PluginApi
        syrus_plugin #{plugin_name.inspect} do
          #{dependency_declaration}
          provides callbacks: "ExternalLoaderFixture::Provider"
          route :get, "/loader-fixture", to: "loader_fixture#show"
        end
        class Provider; end
      end
    RUBY
    directory
  end

  it "validates requires_syrus in an external manifest" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", requires_syrus: "definitely invalid (")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)

      expect { described_class.new(plugin_roots: roots).ordered_plugins }
        .to raise_error(Syrus::PluginLoader::Error, /malformed requires_syrus/)
    end
  end

  it "skips and reports an external plugin requiring a newer Syrus release" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", requires_syrus: ">= 9.0")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      allow(SyrusVersion).to receive(:release).and_return(Gem::Version.new("1.0"))

      described_class.new(plugin_roots: roots).load!

      expect(defined?(ExternalLoaderFixture)).to be_nil
      status = Syrus::PluginRegistry.health.status("external_loader_fixture")
      expect(status.state).to eq(:incompatible)
      expect(status.reasons.join).to include(">= 9.0", "1.0")
    ensure
      Syrus::PluginRegistry.restore(snapshot) if snapshot
    end
  end

  it "loads an external plugin when its requirement is satisfied" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", requires_syrus: ">= 1.0")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      allow(SyrusVersion).to receive(:release).and_return(Gem::Version.new("1.2"))

      described_class.new(plugin_roots: roots).load!

      expect(defined?(ExternalLoaderFixture)).to eq("constant")
    ensure
      Syrus::PluginRegistry.restore(snapshot) if snapshot
      Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
    end
  end

  it "loads an external plugin and notes the skipped check when the running release is unknown" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", requires_syrus: ">= 1.0")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      allow(SyrusVersion).to receive(:release).and_return(nil)

      described_class.new(plugin_roots: roots).load!

      status = Syrus::PluginRegistry.health.status("external_loader_fixture")
      expect(defined?(ExternalLoaderFixture)).to eq("constant")
      expect(status.state).to eq(:ok)
      expect(status.reasons.join).to include("unknown", "skipped")
    ensure
      Syrus::PluginRegistry.restore(snapshot) if snapshot
      Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
    end
  end

  it "ignores requires_syrus for built-in plugins" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app")
      built_in_root = app_root.join("plugins").tap(&:mkpath)
      write_plugin(built_in_root, directory_name: "fixture", gem_name: "external_loader_fixture", requires_syrus: "malformed (")

      plugin = described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root)).ordered_plugins.first

      expect(plugin.requires_syrus).to be_nil
    end
  end
  it "registers every built-in declaration once with the same extension points" do
    entry_files = Syrus::PluginRoots.default.plugin_directories.map do |directory|
      directory.glob("lib/*.rb").find { |file| file.read.include?("syrus_plugin") }
    end.compact
    expected_names = entry_files.map { |file| file.read.match(/syrus_plugin\s+["']([^"']+)/)[1] }
    manifests = Syrus::PluginRegistry.all_plugins
    definitions = ObjectSpace.each_object(Module).filter_map do |namespace|
      next unless namespace.respond_to?(:syrus_plugin_definition)

      definition = namespace.syrus_plugin_definition
      [ definition.name, definition ] if definition
    end.to_h

    expect(manifests.map(&:name)).to contain_exactly(*expected_names)
    expect(manifests.map(&:name).uniq).to eq(manifests.map(&:name))
    manifests.each do |manifest|
      expect(manifest.provides).to eq(definitions.fetch(manifest.name).resolved_provides)
    end
  end

  it "loads an external plugin, registers its provider, and records its route" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app")
      external_root = Pathname.new(temporary).join("external")
      app_root.join("plugins").mkpath
      external_root.mkpath
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)

      described_class.new(plugin_roots: roots).load!
      ExternalLoaderFixture.register!
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "external_loader_fixture" }

      expect(manifest.provides.fetch(:callbacks)).to eq(ExternalLoaderFixture::Provider)
      expect(manifest.metadata.fetch(:routes)).to include(
        verb: "GET", path: "/loader-fixture", controller: "loader_fixture#show"
      )
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/loader-fixture"))
      mounted_route = PluginRouteResolver.find(request, controller_prefix: "loader_fixture")
      expect(mounted_route).to have_attributes(plugin_name: "external_loader_fixture", path: "/loader-fixture")
    ensure
      Syrus::PluginRegistry.restore(snapshot) if snapshot && defined?(Syrus::PluginRegistry)
      Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
    end
  end

  it "orders plugins after their declared plugin dependencies" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app")
      built_in_root = app_root.join("plugins")
      built_in_root.mkpath
      write_plugin(built_in_root, directory_name: "dependent", gem_name: "external_loader_fixture", plugin_name: "dependent", dependencies: [ "base" ])
      write_plugin(built_in_root, directory_name: "base", gem_name: "base_fixture", plugin_name: "base")
      roots = Syrus::PluginRoots.new(application_root: app_root)

      expect(described_class.new(plugin_roots: roots).ordered_plugins.map(&:name)).to eq(%w[base dependent])
    end
  end

  it "keeps a built-in plugin when a differently named external directory declares the same plugin name" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app")
      built_in_root = app_root.join("plugins")
      external_root = Pathname.new(temporary).join("external")
      built_in_root.mkpath
      external_root.mkpath
      built_in = write_plugin(
        built_in_root,
        directory_name: "bundled_directory",
        gem_name: "bundled_fixture",
        plugin_name: "shared_name"
      )
      write_plugin(
        external_root,
        directory_name: "unrelated_directory",
        gem_name: "external_loader_fixture",
        plugin_name: "shared_name"
      )
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)

      plugins = described_class.new(plugin_roots: roots).ordered_plugins

      expect(plugins.map(&:name)).to eq([ "shared_name" ])
      expect(plugins.first.directory).to eq(built_in)
    end
  end

  it "rejects duplicate declared names within the external plugin root" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app")
      external_root = Pathname.new(temporary).join("external")
      app_root.join("plugins").mkpath
      external_root.mkpath
      write_plugin(external_root, directory_name: "first", gem_name: "first_fixture", plugin_name: "shared_name")
      write_plugin(external_root, directory_name: "second", gem_name: "second_fixture", plugin_name: "shared_name")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)

      expect { described_class.new(plugin_roots: roots).ordered_plugins }
        .to raise_error(Syrus::PluginLoader::Error, /Plugin name "shared_name" is declared by multiple manifests/)
    end
  end
  it "rejects gem dependencies declared by an external plugin" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app")
      external_root = Pathname.new(temporary).join("external")
      app_root.join("plugins").mkpath
      external_root.mkpath
      write_plugin(
        external_root,
        directory_name: "fixture",
        gem_name: "external_loader_fixture",
        gem_dependencies: [ [ "rack", ">= 3" ] ]
      )
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)

      expect { described_class.new(plugin_roots: roots).ordered_plugins }
        .to raise_error(Syrus::PluginLoader::Error, /may not declare gem dependencies.*rack/)
    end
  end
end
