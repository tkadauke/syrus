require "rails_helper"
require "syrus/plugin/preview_provider"

RSpec.describe PreviewCommandSource do
  let(:workspace) { Dir.mktmpdir }
  after { FileUtils.rm_rf(workspace) }

  def write_syrus_yml(content)
    File.write(File.join(workspace, ".syrus.yml"), content)
  end

  describe "#resolve" do
    context "with a .syrus.yml preview section" do
      before do
        write_syrus_yml(<<~YAML)
          preview:
            start: "bin/server -p $PORT"
            seed: "bin/seed"
            health_check: "/health"
            logs:
              - "log/server.log"
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

      it "returns health_check_path from yml" do
        result = described_class.new(workspace).resolve
        expect(result.health_check_path).to eq("/health")
      end

      it "returns log_paths from yml" do
        result = described_class.new(workspace).resolve
        expect(result.log_paths).to eq([ "log/server.log" ])
      end
    end

    context "without a .syrus.yml preview section" do
      before do
        write_syrus_yml("prepare: []\n")
      end

      it "falls through to registered plugins" do
        provider = instance_double(
          "TestPreviewProvider",
          detect?: true,
          start_command: "node server.js",
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

      it "returns nil when no plugin detects the repo" do
        result = described_class.new(workspace).resolve
        expect(result).to be_nil
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
