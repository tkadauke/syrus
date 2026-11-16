require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginLoader do
  def write_plugin(root, directory_name:, gem_name:, plugin_name: gem_name, dependencies: [], gem_dependencies: [])
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
