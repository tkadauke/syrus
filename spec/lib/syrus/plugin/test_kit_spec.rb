require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Syrus::Plugin::TestKit do
  let(:manifest) { Syrus::Plugin::Manifest.new(name: "broken", version: "1.0.0", provides: {}, metadata: {}) }
  let(:plugin) { instance_double(Syrus::Plugin::TestKit::PluginUnderTest, name: "broken", manifest:, root: Pathname.new(Dir.tmpdir)) }

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

  it "reports a missing route with the response status" do
    session = ActionDispatch::Integration::Session.new(Rails.application)

    expect { expect(plugin).to have_plugin_route("/definitely-missing").using(session) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /got \d+/)
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
