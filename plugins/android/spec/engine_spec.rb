require "rails_helper"
require "tmpdir"

RSpec.describe Android::Engine do
  def write(rel, contents = "")
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "android" }
    end

    before do
      # The to_prepare block runs at boot; plugin_registry.rb resets the
      # in-memory registry in test mode. Re-register here so examples see the
      # manifest. Interface modules were included during boot and remain on the
      # provider classes.
      unless Syrus::PluginRegistry.registered_names.include?("android")
        Syrus::PluginRegistry.register(
          name:             "android",
          version:          Syrus::PluginApi.default_version,
          description:      "Android project intelligence: Android Gradle Plugin detection, " \
                            "Android/JVM prompt guidance, and mobile review criteria",
          homepage:         "https://github.com/tkadauke/syrus",
          category:         "platform_delivery",
          prepare_priority: 47,
          depends_on:       [ "java", "kotlin" ],
          provides: {
            prepare_detector:         Android::PrepareDetector,
            prompt_injector:          Android::PromptContext,
            review_criteria_provider: Android::ReviewCriteriaProvider
          }
        )
      end
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata and JVM dependencies" do
      expect(registration.version).to eq(Syrus::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(47)
      expect(registration.category).to eq("platform_delivery")
      expect(registration.depends_on).to eq([ "java", "kotlin" ])
    end

    it "provides only immediately safe extension points" do
      expect(registration.provides.keys).to contain_exactly(
        :prepare_detector,
        :prompt_injector,
        :review_criteria_provider
      )
    end

    it "registers Android extension providers" do
      expect(registration.provides[:prepare_detector]).to eq(Android::PrepareDetector)
      expect(registration.provides[:prompt_injector]).to eq(Android::PromptContext)
      expect(registration.provides[:review_criteria_provider]).to eq(Android::ReviewCriteriaProvider)
    end
  end

  describe Android::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-android-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    it "does not detect a repo with no Android signal" do
      expect(described_class.detect?(@dir)).to be false
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "detects Android Gradle Plugin projects using the Groovy plugins DSL" do
      write("build.gradle", <<~GRADLE)
        plugins {
          id 'com.android.application' version '8.7.0' apply false
        }
      GRADLE

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects Android Gradle Plugin projects using the Kotlin plugins DSL" do
      write("build.gradle.kts", <<~GRADLE)
        plugins {
          id("com.android.library") version "8.7.0" apply false
        }
      GRADLE

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects Android Gradle Plugin buildscript classpaths" do
      write("build.gradle", <<~GRADLE)
        buildscript {
          dependencies {
            classpath 'com.android.tools.build:gradle:8.7.0'
          }
        }
      GRADLE

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects Kotlin Android plugin declarations" do
      write("app/build.gradle.kts", <<~GRADLE)
        plugins {
          kotlin("android") version "2.1.0"
        }
      GRADLE

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects conventional Android manifest paths" do
      write("app/src/main/AndroidManifest.xml", "<manifest />")

      expect(described_class.detect?(@dir)).to be true
    end

    it "does not invent SDK-heavy prepare commands in the scaffold" do
      write("app/src/main/AndroidManifest.xml", "<manifest />")

      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "uses the shared JVM mise version file" do
      expect(described_class.mise_version_file).to eq(".java-version")
    end

    it "labels JVM and Android command spans for worker-health diagnostics" do
      labels = described_class.span_labels

      android_gradle_label = labels.find { |(pattern, _)| pattern.match?("./gradlew --no-daemon assembleDebug") }

      expect(android_gradle_label.last).to eq("android gradle")
      expect(labels.find { |(pattern, _)| pattern.match?("adb devices") }.last).to eq("adb")
      expect(labels.find { |(pattern, _)| pattern.match?("java -version") }.last).to eq("java version")
    end
  end

  describe Android::PromptContext do
    it "documents the Linux and provider-neutral visual Runtime boundary" do
      prompt = described_class.call(repository: nil, job: nil)

      expect(prompt).to include("Linux execution")
      expect(prompt).to include("visual frame and input contract")
      expect(prompt).to include("do not invent an `os: android` target")
    end
  end

  describe Android::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-android-review-criteria") { |dir| @dir = dir; ex.run }
    end

    it "adds Android review criteria only for Android repositories" do
      expect(described_class.criteria(@dir)).to eq([])

      write("app/src/main/AndroidManifest.xml", "<manifest />")

      expect(described_class.criteria(@dir)).to include(
        "Flag emulator or device control paths that bypass the generic Runtime Session visual frame/input contract"
      )
    end
  end
end
