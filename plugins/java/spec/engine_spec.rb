require "rails_helper"
require "tmpdir"

RSpec.describe Java::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "java" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("java")
        Syrus::PluginRegistry.register(
          name:             "java",
          version:          Syrus::PluginApi.default_version,
          description:      "Java/JVM-generic intelligence: Gradle/Maven wrapper-aware prepare detection, JDK prompt guidance, and JVM review criteria",
          homepage:         "https://github.com/tkadauke/syrus",
          category:         "language",
          prepare_priority: 45,
          provides: {
            prepare_detector:         Java::PrepareDetector,
            prompt_injector:          Java::PromptContext,
            review_criteria_provider: Java::ReviewCriteriaProvider
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

    it "registers with the correct metadata" do
      expect(registration.version).to eq(Syrus::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(45)
      expect(registration.category).to eq("language")
    end

    it "provides exactly the expected extension point keys" do
      expect(registration.provides.keys).to contain_exactly(
        :prepare_detector,
        :prompt_injector,
        :review_criteria_provider
      )
    end

    it "registers PrepareDetector as the :prepare_detector" do
      expect(registration.provides[:prepare_detector]).to eq(Java::PrepareDetector)
    end

    it "registers PromptContext as the :prompt_injector" do
      expect(registration.provides[:prompt_injector]).to eq(Java::PromptContext)
    end

    it "registers ReviewCriteriaProvider as the :review_criteria_provider" do
      expect(registration.provides[:review_criteria_provider]).to eq(Java::ReviewCriteriaProvider)
    end
  end

  describe Java::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-java-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "does not detect a repo with no recognized Java/JVM signal" do
      expect(described_class.detect?(@dir)).to be false
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "prefers a Gradle wrapper when present" do
      write("build.gradle")
      write("gradlew")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "./gradlew --no-daemon testClasses" ])
    end

    it "falls back to a system Gradle command for Gradle build files" do
      write("build.gradle.kts")

      expect(described_class.prepare_commands(@dir)).to eq([ "gradle --no-daemon testClasses" ])
    end

    it "detects Gradle settings files as Gradle projects" do
      write("settings.gradle.kts")

      expect(described_class.prepare_commands(@dir)).to eq([ "gradle --no-daemon testClasses" ])
    end

    it "prefers a Maven wrapper when present" do
      write("pom.xml")
      write("mvnw")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "./mvnw -B test-compile" ])
    end

    it "falls back to a system Maven command for pom.xml" do
      write("pom.xml")

      expect(described_class.prepare_commands(@dir)).to eq([ "mvn -B test-compile" ])
    end

    it "detects the Maven wrapper metadata as a Maven project" do
      write(".mvn/wrapper/maven-wrapper.properties")

      expect(described_class.prepare_commands(@dir)).to eq([ "mvn -B test-compile" ])
    end

    it "prefers Gradle when both Gradle and Maven signals are present" do
      write("build.gradle")
      write("pom.xml")

      expect(described_class.prepare_commands(@dir)).to eq([ "gradle --no-daemon testClasses" ])
    end

    it "detects conventional Java source paths without inventing a prepare command" do
      write("src/main/java/example/App.java")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "declares .java-version as its mise version file" do
      expect(described_class.mise_version_file).to eq(".java-version")
    end

    describe ".span_labels" do
      it "labels Gradle, Maven, java -version, and javac spans for worker-health diagnostics" do
        labels = described_class.span_labels

        expect(labels.find { |(pattern, _)| pattern.match?("./gradlew --no-daemon testClasses") }.last).to eq("gradle")
        expect(labels.find { |(pattern, _)| pattern.match?("mvn -B test-compile") }.last).to eq("maven")
        expect(labels.find { |(pattern, _)| pattern.match?("java -version") }.last).to eq("java version")
        expect(labels.find { |(pattern, _)| pattern.match?("javac src/main/java/App.java") }.last).to eq("javac")
      end

      it "does not match unrelated commands" do
        labels = described_class.span_labels

        expect(labels.any? { |(pattern, _)| pattern.match?("npm test") }).to be false
      end
    end
  end

  describe Java::PromptContext do
    it "returns wrapper, JDK, and Android-boundary guidance" do
      text = described_class.call(repository: nil, job: nil)

      expect(text).to include("./gradlew")
      expect(text).to include("./mvnw")
      expect(text).to include(".java-version")
      expect(text).to include("Android")
    end
  end

  describe Java::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-java-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns [] for a repo with no recognized Java/JVM signal" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the InterruptedException criterion when a Java/JVM project is detected" do
      write("pom.xml")

      expect(described_class.criteria(@dir)).to eq([ "Flag swallowed InterruptedException without restoring interrupt status" ])
    end
  end
end
