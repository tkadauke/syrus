require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Syrus::Plugin::TestKit do
  let(:manifest) { Syrus::Plugin::Manifest.new(name: "broken", version: "1.0.0", provides: {}, metadata: {}) }
  let(:plugin) { instance_double(Syrus::Plugin::TestKit::PluginUnderTest, name: "broken", manifest:, root: Pathname.new(Dir.tmpdir)) }

  class ValidCallbacks
    include Syrus::Plugin::Callbacks
  end

  class InvalidCallbacks
  end

  describe ValidCallbacks do
    subject { described_class.new }

    it_behaves_like "a valid Syrus plugin provider", :callbacks
  end

  describe InvalidCallbacks do
    subject { described_class.new }

    it "reports a provider that does not implement the contract" do
      expect do
        interface = Syrus::PluginRegistry::INTERFACE_FOR.fetch(:callbacks).call
        expect(subject.class.ancestors).to include(interface)
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /include Syrus::Plugin::Callbacks/)
    end
  end

  it "loads a plugin directory into an isolated registry and restores the host registry" do
    original_names = Syrus::PluginRegistry.all_plugins.map(&:name)
    Dir.mktmpdir("test-kit-external") do |parent|
      root = Pathname.new(parent).join("isolated_test_kit_plugin")
      root.join("lib").mkpath
      root.join("isolated_test_kit_plugin.gemspec").write(<<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "isolated_test_kit_plugin"
          spec.version = "1.0.0"
          spec.summary = "Test kit fixture"
          spec.authors = ["Syrus"]
          spec.files = []
          spec.add_dependency "rails", ">= 8.1"
          spec.metadata["requires_syrus"] = ">= 0.1.0"
        end
      RUBY
      root.join("lib/isolated_test_kit_plugin.rb").write(<<~RUBY)
        module IsolatedTestKitPlugin
          extend Syrus::PluginApi
          syrus_plugin "isolated_test_kit_plugin" do
            provides callbacks: "IsolatedTestKitPlugin::Callbacks"
          end
          class Callbacks; end
        end
      RUBY

      with_syrus_plugin(root) do |loaded|
        expect(loaded).to be_plugin_loaded
        expect(loaded).to register_plugin_provider(:callbacks)
      end
    end

    expect(Syrus::PluginRegistry.all_plugins.map(&:name)).to eq(original_names)
  end

  it "reports a missing provider with the extension point" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:callbacks).and_return([])

    expect { expect(plugin).to register_plugin_provider(:callbacks) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /provider for callbacks/)
  end

  it "reports a plugin that was not loaded" do
    expect { expect(plugin).to be_plugin_loaded }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /manifest was/)
  end

  it "accepts a healthy plugin and reports an unhealthy plugin's reasons" do
    allow(plugin).to receive(:health).and_return(Syrus::PluginHealth::Status.new(name: "broken", state: :ok, reasons: []))
    expect(plugin).to be_plugin_healthy

    allow(plugin).to receive(:health).and_return(Syrus::PluginHealth::Status.new(name: "broken", state: :failed, reasons: [ "boot exploded" ]))
    expect { expect(plugin).to be_plugin_healthy }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /failed: boot exploded/)
  end

  it "reports a missing route with the response status" do
    session = ActionDispatch::Integration::Session.new(Rails.application)

    expect { expect(plugin).to have_plugin_route("/definitely-missing").using(session) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /got \d+/)
  end

  it "reports a missing route session as a matcher failure" do
    expect { expect(plugin).to have_plugin_route("/plugin") }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /requires \.using/)
  end

  it "reports a migration that fails" do
    Dir.mktmpdir("broken-plugin-migration") do |directory|
      root = Pathname.new(directory)
      root.join("db/migrate").mkpath
      root.join("db/migrate/20261118000000_break_plugin.rb").write(<<~RUBY)
        class BreakPlugin < ActiveRecord::Migration[8.1]
          def change
            raise "migration exploded"
          end
        end
      RUBY
      broken = instance_double(Syrus::Plugin::TestKit::PluginUnderTest, name: "broken", root:)

      expect { expect(broken).to have_applicable_plugin_migrations }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /migration exploded/)
    end
  end

  it "reports missing locale languages" do
    allow(plugin).to receive(:frontend).and_return(
      locales: [ { locale: "en", namespace: "broken", url: "/en" } ]
    )

    expect { expect(plugin).to have_matching_plugin_locales }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /de\/broken, la\/broken/)
  end

  it "accepts a matching frontend hash and reports a missing bundle" do
    Dir.mktmpdir("plugin-frontend") do |directory|
      path = Pathname.new(directory).join("bundle.js")
      path.write("export default true")
      asset = PluginFrontendAssets::Asset.new(plugin_name: "broken", kind: :bundle, path:, content_type: "text/javascript", hash: nil)
      hash = Digest::SHA256.file(path).hexdigest
      allow(plugin).to receive(:frontend).and_return({ name: "broken", hash: })
      allow(PluginFrontendAssets).to receive(:find).with("broken", :bundle).and_return(asset)
      allow(PluginFrontendAssets).to receive(:find).with("broken", :css).and_return(nil)
      expect(plugin).to have_plugin_frontend

      allow(PluginFrontendAssets).to receive(:find).with("broken", :bundle).and_return(nil)
      expect { expect(plugin).to have_plugin_frontend }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /frontend bundle whose hash matches bootstrap/)
    end
  end

  it "accepts a catalogued CLI command and reports a missing one" do
    command = instance_double(Syrus::Plugin::CliCommand, plugin: "broken", path: %w[plugin ping])
    allow(PluginCliCommands).to receive(:catalog).and_return([ command ])
    expect(plugin).to have_plugin_cli_command("plugin", "ping")

    expect { expect(plugin).to have_plugin_cli_command("plugin", "missing") }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /CLI command plugin missing to be present/)
  end

  it "accepts a valid manifest and reports validation errors" do
    specification = Gem::Specification.new("broken", "1.0.0")
    allow(plugin).to receive(:specification).and_return(specification)
    expect(plugin).to have_valid_plugin_manifest

    allow(plugin).to receive(:manifest).and_return(manifest.with(validation_errors: [ "missing version" ]))
    expect { expect(plugin).to have_valid_plugin_manifest }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /missing version/)
  end

  it "accepts a clean host surface and reports unsupported constants" do
    clean = Syrus::PluginHostSurface::Scanner::Result.new(public: [], legacy: [], unlisted: [], minimum_syrus_version: nil, content_hash: "clean", error: nil)
    finding = Syrus::PluginHostSurface::Scanner::Finding.new(constant: "Syrus::PrivateApi", tier: "unlisted", path: "lib/broken.rb", line: 1)
    dirty = clean.with(unlisted: [ finding ])
    scanner = instance_double(Syrus::PluginHostSurface::Scanner, call: clean)
    allow(Syrus::PluginHostSurface::Scanner).to receive(:new).with(plugin.root).and_return(scanner)
    expect(plugin).to have_clean_plugin_host_surface

    allow(scanner).to receive(:call).and_return(dirty)
    expect { expect(plugin).to have_clean_plugin_host_surface }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Syrus::PrivateApi/)
  end

  it "builds host records without the repository's test factories" do
    stub_const("Factories", Module.new do
      def self.method_missing(*) = raise("repository factory leaked")
    end)

    user = build_plugin_user
    repository = build_plugin_repository(user:)
    job = build_plugin_job(user:, repository:)

    expect(job).to have_attributes(user:, repository:)
  end

  it "reports an unsatisfied requires_syrus requirement" do
    specification = Gem::Specification.new do |spec|
      spec.name = "broken"
      spec.version = "1.0.0"
      spec.summary = "broken"
      spec.authors = [ "test" ]
      spec.metadata["requires_syrus"] = ">= 999.0"
    end
    allow(plugin).to receive(:specification).and_return(specification)
    allow(SyrusVersion).to receive(:release).and_return(Gem::Version.new("1.0.0"))

    expect { expect(plugin).to satisfy_requires_syrus }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /requires_syrus.*999/)
  end
end
