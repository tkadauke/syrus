require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::PluginLoader do
  def write_plugin(root, directory_name:, gem_name:, plugin_name: gem_name, dependencies: [], optional_dependencies: [], gem_dependencies: [], requires_syrus: nil, roles: nil)
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
    dependency_declaration += "\n  optionally_depends_on #{optional_dependencies.inspect}" if optional_dependencies.any?
    role_declaration = roles.nil? ? "" : "roles #{roles.inspect}"
    directory.join("lib/#{gem_name}.rb").write(<<~RUBY)
      module ExternalLoaderFixture
        extend Syrus::PluginApi
        syrus_plugin #{plugin_name.inspect} do
          default_enabled true
          disableable true
          experimental false
          requires_syrus #{requires_syrus.inspect}
          #{dependency_declaration}
          #{role_declaration}
          provides callbacks: "ExternalLoaderFixture::Provider"
          route :get, "/loader-fixture", to: "loader_fixture#show"
        end
        class Provider; end
      end
    RUBY
    directory
  end

  it "loads plugins listed for the process role and defaults omitted roles to all" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", roles: %w[preview])
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      original_role = ENV["SYRUS_ROLE"]
      ENV["SYRUS_ROLE"] = "preview"

      described_class.new(plugin_roots: roots).load!

      expect(defined?(ExternalLoaderFixture)).to eq("constant")
    ensure
      ENV["SYRUS_ROLE"] = original_role
      Syrus::PluginRegistry.restore(snapshot) if snapshot
      Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
    end
  end

  it "loads roles declared with the documented percent-word syntax" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      directory = write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture")
      entry_file = directory.join("lib/external_loader_fixture.rb")
      entry_file.write(entry_file.read.sub("provides callbacks:", "roles %w[preview]\n    provides callbacks:"))
      original_role = ENV["SYRUS_ROLE"]
      ENV["SYRUS_ROLE"] = "web"

      described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)).load!

      expect(defined?(ExternalLoaderFixture)).to be_nil
      expect(Syrus::PluginRegistry.health.status("external_loader_fixture").reasons.join).to include("web", "preview")
    ensure
      ENV["SYRUS_ROLE"] = original_role
      Syrus::PluginRegistry.restore(snapshot) if snapshot
      Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
    end
  end

  it "skips plugins not listed for the process role and records plugin health" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", roles: %w[worker])
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      original_role = ENV["SYRUS_ROLE"]
      ENV["SYRUS_ROLE"] = "web"

      described_class.new(plugin_roots: roots).load!

      expect(defined?(ExternalLoaderFixture)).to be_nil
      expect(Syrus::PluginRegistry.health.status("external_loader_fixture").reasons.join).to include("web", "worker")
    ensure
      ENV["SYRUS_ROLE"] = original_role
      Syrus::PluginRegistry.restore(snapshot) if snapshot
    end
  end

  it "rejects invalid plugin roles" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture", roles: %w[database])

      expect { described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)).ordered_plugins }
        .to raise_error(Syrus::PluginLoader::Error, /invalid process roles: database/)
    end
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

  it "validates requires_syrus in a synced manifest" do
    Dir.mktmpdir do |temporary|
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      synced_root = Pathname.new(temporary).join("synced").tap(&:mkpath)
      write_plugin(synced_root, directory_name: "fixture", gem_name: "synced_loader_fixture", requires_syrus: "definitely invalid (")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: nil, synced_path: synced_root)

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

  it "defers a real host-surface scan until application preparation" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture")
      roots = Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      allow(Syrus::PluginHostSurface::Scanner).to receive(:cached).and_call_original

      described_class.new(plugin_roots: roots).load!

      expect(Syrus::PluginHostSurface::Scanner).not_to have_received(:cached)
      described_class.scan_external_plugins!
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "external_loader_fixture" }
      scan = manifest.metadata.fetch(:plugin_host_surface_scan)
      expect(scan.error).to be_nil
      expect(scan.public.map(&:constant)).to include("Syrus::PluginApi")
      expect(Syrus::PluginHostSurface::Scanner).to have_received(:cached).with(manifest.plugin_root).once
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
    expected_entries = entry_files.to_h do |file|
      [ file.read.match(/syrus_plugin\s+["']([^"']+)/)[1], file.dirname.expand_path ]
    end
    expected_names = expected_entries.keys
    manifests = Syrus::PluginRegistry.all_plugins
    definitions = ObjectSpace.each_object(Module).filter_map do |namespace|
      definition = namespace.instance_variable_get(:@syrus_plugin_definition)
      next unless definition
      next unless Pathname.new(definition.lib_dir).expand_path == expected_entries[definition.name]

      [ definition.name, definition ]
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

  it "isolates a plugin that still registers a removed Ecosystem point and reports plugin health" do
    Dir.mktmpdir do |temporary|
      snapshot = Syrus::PluginRegistry.snapshot
      app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
      external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
      directory = write_plugin(external_root, directory_name: "fixture", gem_name: "external_loader_fixture")
      entry_file = directory.join("lib/external_loader_fixture.rb")
      entry_file.write(entry_file.read.sub("provides callbacks:", "provides prepare_detector:"))

      described_class.new(
        plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)
      ).load!
      definition = ExternalLoaderFixture.instance_variable_get(:@syrus_plugin_definition)
      expect { described_class.install_definition!(definition) }.not_to raise_error

      status = Syrus::PluginRegistry.health.status("external_loader_fixture")
      expect(status.state).to eq(:failed)
      expect(status.reasons.join).to include("Unknown extension point :prepare_detector")
    ensure
      Syrus::PluginRegistry.restore(snapshot) if snapshot
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

  describe "boot isolation" do
    def overwrite_entry(directory, gem_name, source)
      directory.join("lib/#{gem_name}.rb").write(source)
    end

    it "turns an obsolete external Toolkit declaration into health evidence and keeps booting" do
      Dir.mktmpdir do |temporary|
        snapshot = Syrus::PluginRegistry.snapshot
        app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
        external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
        healthy = write_plugin(external_root, directory_name: "healthy_toolkit", gem_name: "healthy_toolkit_fixture")
        obsolete = write_plugin(external_root, directory_name: "obsolete_toolkit", gem_name: "obsolete_toolkit_fixture")
        overwrite_entry(obsolete, "obsolete_toolkit_fixture", <<~RUBY)
          module ObsoleteToolkitFixture
            extend Syrus::PluginApi
            syrus_plugin "obsolete_toolkit_fixture" do
              provides toolkit: "ObsoleteToolkitFixture::Provider", implements: %i[removed_toolkit_api]
            end
          end
        RUBY

        loader = described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root))
        expect { loader.load! }.not_to raise_error

        described_class.install_definition!(ExternalLoaderFixture.syrus_plugin_definition)
        status = Syrus::PluginRegistry.health.status("obsolete_toolkit_fixture")
        expect(status.state).to eq(:failed)
        expect(status.reasons.join).to include("removed_toolkit_api")
        expect(Syrus::PluginRegistry.all_plugins.map(&:name)).to include("healthy_toolkit_fixture")
      ensure
        Syrus::PluginRegistry.restore(snapshot) if snapshot
        Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
        Object.send(:remove_const, :ObsoleteToolkitFixture) if defined?(ObsoleteToolkitFixture)
      end
    end

    it "isolates StandardError, LoadError, and syntax failures while loading healthy plugins" do
      Dir.mktmpdir do |temporary|
        snapshot = Syrus::PluginRegistry.snapshot
        app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
        external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
        healthy = write_plugin(external_root, directory_name: "healthy", gem_name: "healthy_fixture")
        standard = write_plugin(external_root, directory_name: "standard", gem_name: "standard_fixture")
        load_error = write_plugin(external_root, directory_name: "load_error", gem_name: "load_error_fixture")
        syntax = write_plugin(external_root, directory_name: "syntax", gem_name: "syntax_fixture")
        overwrite_entry(standard, "standard_fixture", <<~RUBY)
          module StandardFixture
            extend Syrus::PluginApi
            class Provider; end
            syrus_plugin "standard_fixture" do
              default_enabled true
              disableable true
              experimental false
              requires_syrus nil
              provides callbacks: "StandardFixture::Provider"
              route :get, "/failed-require", to: "failed_require#show"
            end
            raise "broken standard"
          end
        RUBY
        overwrite_entry(load_error, "load_error_fixture", "module LoadErrorFixture\n  extend Syrus::PluginApi\n  syrus_plugin \"load_error_fixture\" do\n    default_enabled true\n    disableable true\n    experimental false\n    requires_syrus nil\n  end\n  raise LoadError, \"missing helper\"\nend\n")
        overwrite_entry(syntax, "syntax_fixture", "module SyntaxFixture\n  extend Syrus::PluginApi\n  syrus_plugin \"syntax_fixture\" do; end\n  def broken(\nend\n")

        expect { described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root)).load! }
          .not_to raise_error

        expect(defined?(ExternalLoaderFixture)).to eq("constant")
        described_class.install_definition!(ExternalLoaderFixture.syrus_plugin_definition)
        described_class.install_definition!(StandardFixture.syrus_plugin_definition)
        described_class.install_definition!(LoadErrorFixture.syrus_plugin_definition)

        expect(Syrus::PluginRegistry.providers_for(:callbacks)).to include(ExternalLoaderFixture::Provider)
        %w[standard_fixture load_error_fixture syntax_fixture].each do |name|
          status = Syrus::PluginRegistry.health.status(name)
          expect(status.state).to eq(:failed)
          expect(status.reasons.join).not_to be_empty
        end
        expect(Syrus::PluginRegistry.providers_for(:callbacks)).not_to include(StandardFixture::Provider)
        failed_manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "standard_fixture" }
        expect(failed_manifest.metadata[:routes]).to be_nil
        expect(StandardFixture.const_defined?(:Engine, false)).to be(false)
        expect(LoadErrorFixture.const_defined?(:Engine, false)).to be(false)
        request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/failed-require"))
        expect(PluginRouteResolver.find(request, controller_prefix: "failed_require")).to be_nil
      ensure
        Syrus::PluginRegistry.restore(snapshot) if snapshot
        Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
        Object.send(:remove_const, :StandardFixture) if defined?(StandardFixture)
        Object.send(:remove_const, :LoadErrorFixture) if defined?(LoadErrorFixture)
        Object.send(:remove_const, :SyntaxFixture) if defined?(SyntaxFixture)
      end
    end

    # DOC-44: optional dependency absence cannot disable the dependent plugin.
    it "still loads a plugin whose optional dependency raised during boot" do
      Dir.mktmpdir do |temporary|
        snapshot = Syrus::PluginRegistry.snapshot
        app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
        external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
        broken = write_plugin(external_root, directory_name: "broken", gem_name: "atomic_fixture")
        write_plugin(external_root, directory_name: "dependent", gem_name: "dependent_fixture", optional_dependencies: [ "atomic_fixture" ])
        overwrite_entry(broken, "atomic_fixture", <<~RUBY)
          module AtomicFixture
            extend Syrus::PluginApi
            syrus_plugin "atomic_fixture" do
              default_enabled true
              disableable true
              experimental false
              requires_syrus nil
              on_boot { raise "after registry write" }
            end
          end
        RUBY
        loader = described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root))
        loader.load!

        described_class.install_definition!(AtomicFixture.syrus_plugin_definition)
        described_class.install_definition!(ExternalLoaderFixture.syrus_plugin_definition)

        expect(Syrus::PluginRegistry.health.status("atomic_fixture").state).to eq(:failed)
        expect(Syrus::PluginRegistry.health.status("dependent_fixture").state).to eq(:ok)
        expect(Syrus::PluginRegistry.providers_for(:callbacks)).to include(ExternalLoaderFixture::Provider)
      ensure
        Syrus::PluginRegistry.restore(snapshot) if snapshot
        Object.send(:remove_const, :AtomicFixture) if defined?(AtomicFixture)
        Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
      end
    end

    it "rolls back a plugin that raises after registering and skips its dependent" do
      Dir.mktmpdir do |temporary|
        snapshot = Syrus::PluginRegistry.snapshot
        app_root = Pathname.new(temporary).join("app").tap { |path| path.join("plugins").mkpath }
        external_root = Pathname.new(temporary).join("external").tap(&:mkpath)
        broken = write_plugin(external_root, directory_name: "broken", gem_name: "atomic_fixture")
        write_plugin(external_root, directory_name: "dependent", gem_name: "dependent_fixture", dependencies: [ "atomic_fixture" ])
        overwrite_entry(broken, "atomic_fixture", <<~RUBY)
          module AtomicFixture
            extend Syrus::PluginApi
            syrus_plugin "atomic_fixture" do
              default_enabled true
              disableable true
              experimental false
              requires_syrus nil
              provides callbacks: "AtomicFixture::Provider"
              route :get, "/atomic", to: "atomic#show"
              on_boot { raise "after registry write" }
            end
            class Provider; end
          end
        RUBY
        loader = described_class.new(plugin_roots: Syrus::PluginRoots.new(application_root: app_root, external_path: external_root))
        loader.load!

        described_class.install_definition!(AtomicFixture.syrus_plugin_definition)
        described_class.install_definition!(ExternalLoaderFixture.syrus_plugin_definition)

        expect(Syrus::PluginRegistry.health.status("atomic_fixture").state).to eq(:failed)
        expect(Syrus::PluginRegistry.health.status("dependent_fixture").state).to eq(:skipped_dependency)
        expect(Syrus::PluginRegistry.providers_for(:callbacks)).not_to include(AtomicFixture::Provider)
        expect(Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "atomic_fixture" }.metadata[:routes]).to be_nil
        expect(AtomicFixture.const_defined?(:Engine, false)).to be(false)
        expect(ExternalLoaderFixture.const_defined?(:Engine, false)).to be(false)
        request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/atomic"))
        expect(PluginRouteResolver.find(request, controller_prefix: "atomic")).to be_nil
      ensure
        Syrus::PluginRegistry.restore(snapshot) if snapshot
        Object.send(:remove_const, :AtomicFixture) if defined?(AtomicFixture)
        Object.send(:remove_const, :ExternalLoaderFixture) if defined?(ExternalLoaderFixture)
      end
    end
  end
end
