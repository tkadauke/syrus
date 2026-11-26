require "rails_helper"
require "tmpdir"

RSpec.describe Ios::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "ios" }
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the expected metadata" do
      expect(registration.version).to eq(Syrus::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(48)
      expect(registration.category).to eq("language")
    end

    it "registers its Ecosystem providers and none of the absorbed legacy points" do
      expect(registration.provides).to be_empty
      expect(registration.family_provides.map { |entry| [ entry.provider, entry.capabilities ] }).to contain_exactly(
        [ "Ios::Ecosystem", %i[detect_prepare] ],
        [ "Ios::XcodebuildEcosystem", %i[grader_types] ],
        [ "Ios::SwiftpmEcosystem", %i[grader_types] ]
      )
    end
  end

  describe Ios::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-ios-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "does not detect a repo with no iOS or Swift signal" do
      expect(described_class.detect?(@dir)).to be(false)
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "prepares root Swift packages with dependency resolution" do
      write("Package.swift", "// swift-tools-version: 6.0\n")

      expect(described_class.detect?(@dir)).to be(true)
      expect(described_class.prepare_commands(@dir)).to eq([ "swift package resolve" ])
    end

    it "detects Xcode projects without inventing a scheme-dependent prepare command" do
      write("MobileApp.xcodeproj/project.pbxproj", "")

      expect(described_class.detect?(@dir)).to be(true)
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "labels Xcode and Swift Package Manager command spans" do
      labels = described_class.span_labels

      expect(labels.find { |(pattern, _)| pattern.match?("xcodebuild test -scheme MobileApp") }.last).to eq("xcodebuild")
      expect(labels.find { |(pattern, _)| pattern.match?("swift package resolve") }.last).to eq("swift package")
    end
  end
end
