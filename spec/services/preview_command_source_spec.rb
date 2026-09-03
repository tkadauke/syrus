require "rails_helper"
require "syrus/plugin/preview_provider"

RSpec.describe PreviewCommandSource do
  let(:workspace) { Dir.mktmpdir }
  after do
    FileUtils.rm_rf(workspace)
    Syrus::PluginRegistry.reset!
    Syrus::Plugin::PreviewProvider.registry.clear
  end

  def write_syrus_yml(content)
    File.write(File.join(workspace, ".syrus.yml"), content)
  end

  describe "#resolve" do
    context "with a .syrus.yml preview section" do
      before do
        write_syrus_yml(<<~YAML)
          preview:
            start: "bin/server -p $PORT"
            setup:
              - "bundle install"
            seed: "bin/seed"
            health_check: "/health"
            logs:
              - "log/server.log"
            env:
              RAILS_ENV: development
            unset_env:
              - DATABASE_URL
        YAML
      end

      it "returns a Config with start_command_for callable" do
        result = described_class.new(workspace).resolve
        expect(result).not_to be_nil
        expect(result.start_command_for.call(port: 4000)).to eq("bin/server -p 4000")
      end

      it "interpolates $PORT and ${PORT} in start command" do
        write_syrus_yml(<<~YAML)
          preview:
            start: "PORT=${PORT} node server.js"
        YAML
        result = described_class.new(workspace).resolve
        expect(result.start_command_for.call(port: 5000)).to eq("PORT=5000 node server.js")
      end

      it "returns seed_command from yml" do
        result = described_class.new(workspace).resolve
        expect(result.seed_command).to eq("bin/seed")
      end

      it "returns setup_commands from yml" do
        result = described_class.new(workspace).resolve
        expect(result.setup_commands).to eq([ "bundle install" ])
      end

      it "returns health_check_path from yml" do
        result = described_class.new(workspace).resolve
        expect(result.health_check_path).to eq("/health")
      end

      it "returns log_paths from yml" do
        result = described_class.new(workspace).resolve
        expect(result.log_paths).to eq([ "log/server.log" ])
      end

      it "returns the preview process environment contract from yml" do
        result = described_class.new(workspace).resolve
        expect(result.env).to eq("RAILS_ENV" => "development")
        expect(result.unset_env).to eq([ "DATABASE_URL" ])
      end
    end

    context "without a .syrus.yml preview section" do
      before do
        write_syrus_yml("prepare: []\n")
      end

      it "falls through to registered plugins" do
        provider_class = Class.new do
          include Syrus::Plugin::PreviewProvider

          def detect?(_repo_path) = true
          def start_command(port:) = "node server.js --port #{port}"
        end

        Syrus::PluginRegistry.register(
          name: "preview_plugin", version: "1.0.0",
          provides: { preview_provider: provider_class }
        )

        result = described_class.new(workspace).resolve
        expect(result).not_to be_nil
        expect(result.start_command_for.call(port: 3000)).to eq("node server.js --port 3000")
      end

      it "does not use disabled PluginRegistry preview providers" do
        provider_class = Class.new do
          include Syrus::Plugin::PreviewProvider

          def detect?(_repo_path) = true
          def start_command(port:) = "node server.js --port #{port}"
        end

        Syrus::PluginRegistry.register(
          name: "disabled_preview_plugin", version: "1.0.0",
          provides: { preview_provider: provider_class }
        )
        PluginRecord.find_by!(name: "disabled_preview_plugin").update!(enabled: false)

        expect(described_class.new(workspace).resolve).to be_nil
      end

      it "falls through to legacy direct preview provider registration" do
        provider = instance_double(
          "TestPreviewProvider",
          detect?: true,
          start_command: "node server.js",
          setup_commands: [],
          seed_command: nil,
          health_check_path: "/",
          log_paths: []
        )
        allow(provider).to receive(:start_command).with(port: 3000).and_return("node server.js")

        original_registry = Syrus::Plugin::PreviewProvider.registry.dup
        begin
          Syrus::Plugin::PreviewProvider.registry << provider
          result = described_class.new(workspace).resolve
          expect(result).not_to be_nil
          expect(result.start_command_for.call(port: 3000)).to eq("node server.js")
        ensure
          Syrus::Plugin::PreviewProvider.instance_variable_set(:@registry, original_registry)
        end
      end

      it "uses the first matching plugin and does not call detect? on later ones" do
        non_matching = instance_double("NonMatchingProvider", detect?: false)
        matching     = instance_double(
          "MatchingProvider",
          detect?: true,
          start_command: "bin/rails server",
          setup_commands: [],
          seed_command: nil,
          health_check_path: "/up",
          log_paths: []
        )
        allow(matching).to receive(:start_command).with(port: 4000).and_return("bin/rails server")
        skipped = instance_double("SkippedProvider", detect?: true)

        original_registry = Syrus::Plugin::PreviewProvider.registry.dup
        begin
          Syrus::Plugin::PreviewProvider.registry.replace([ non_matching, matching, skipped ])
          result = described_class.new(workspace).resolve
          expect(result.start_command_for.call(port: 4000)).to eq("bin/rails server")
          expect(result.health_check_path).to eq("/up")
          expect(skipped).not_to have_received(:detect?)
        ensure
          Syrus::Plugin::PreviewProvider.instance_variable_set(:@registry, original_registry)
        end
      end

      it "returns optional env settings from plugins" do
        provider = instance_double(
          "EnvPreviewProvider",
          detect?: true,
          start_command: "bin/server",
          setup_commands: [ "bundle install" ],
          seed_command: nil,
          health_check_path: "/",
          log_paths: [],
          env: { "RAILS_ENV" => "development" },
          unset_env: [ "DATABASE_URL" ]
        )
        allow(provider).to receive(:start_command).with(port: 3000).and_return("bin/server")

        original_registry = Syrus::Plugin::PreviewProvider.registry.dup
        begin
          Syrus::Plugin::PreviewProvider.registry.replace([ provider ])
          result = described_class.new(workspace).resolve
          expect(result.env).to eq("RAILS_ENV" => "development")
          expect(result.unset_env).to eq([ "DATABASE_URL" ])
          expect(result.setup_commands).to eq([ "bundle install" ])
        ensure
          Syrus::Plugin::PreviewProvider.instance_variable_set(:@registry, original_registry)
        end
      end

      it "returns nil when no plugin detects the repo" do
        result = described_class.new(workspace).resolve
        expect(result).to be_nil
      end

      it "reports whether any preview provider is configured" do
        provider_class = Class.new do
          include Syrus::Plugin::PreviewProvider
        end

        # Bundled plugins (syrus-rails) supply a preview provider, so the
        # "nothing configured" branch needs an explicitly empty registry.
        Syrus::PluginRegistry.reset!
        expect(Syrus::Plugin::PreviewProvider.configured?).to be(false)

        Syrus::PluginRegistry.register(
          name: "configured_preview_plugin", version: "1.0.0",
          provides: { preview_provider: provider_class }
        )

        expect(Syrus::Plugin::PreviewProvider.configured?).to be(true)
      end
    end

    context "without a .syrus.yml at all" do
      it "falls through to plugins and returns nil when none registered" do
        result = described_class.new(workspace).resolve
        expect(result).to be_nil
      end
    end

    context "with a malformed .syrus.yml" do
      before do
        write_syrus_yml("preview:\n  start: \"\"\n")
      end

      it "returns nil (parse error treated as absent)" do
        result = described_class.new(workspace).resolve
        expect(result).to be_nil
      end
    end
  end
end
