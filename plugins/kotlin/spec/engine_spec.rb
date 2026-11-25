require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe Kotlin::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "kotlin" }
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata and Java dependency" do
      expect(registration.version).to eq(Syrus::Host::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(46)
      expect(registration.category).to eq("language")
      expect(registration.depends_on).to eq([ "java" ])
    end

    it "registers its Ecosystem provider and none of the absorbed legacy points" do
      expect(registration.provides).to be_empty
      expect(registration.family_provides.map { |entry| [ entry.provider, entry.capabilities ] }).to contain_exactly(
        [ "Kotlin::Ecosystem", %i[detect_prepare prompt_context review_criteria] ]
      )
    end
  end

  describe Kotlin::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-kotlin-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "does not detect a repo with no Kotlin/JVM signal" do
      expect(described_class.detect?(@dir)).to be false
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "detects conventional Kotlin source paths without inventing a prepare command" do
      write("src/main/kotlin/example/App.kt", "fun main() = Unit\n")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "detects Kotlin test source paths" do
      write("src/test/kotlin/example/AppTest.kt", "class AppTest\n")

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects standalone Kotlin source files" do
      write("tools/Migrate.kt", "fun migrate() = Unit\n")

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects a Kotlin file at the repository root" do
      write("Main.kt", "fun main() = Unit\n")

      expect(described_class.detect?(@dir)).to be true
    end

    it "ignores a directory whose name merely ends in .kt" do
      FileUtils.mkdir_p(File.join(@dir, "not-source.kt"))

      expect(described_class.detect?(@dir)).to be false
    end

    it "detects Kotlin scripts" do
      write("scripts/bootstrap.kts", "println(\"hello\")\n")

      expect(described_class.detect?(@dir)).to be true
    end

    it "detects Gradle Kotlin DSL and reuses Java Gradle prepare commands" do
      write("build.gradle.kts", <<~GRADLE)
        plugins {
          kotlin("jvm") version "2.1.0"
        }
      GRADLE
      write("gradlew")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "./gradlew --no-daemon testClasses" ])
    end

    it "detects Kotlin JVM plugin declarations in Groovy Gradle files" do
      write("build.gradle", <<~GRADLE)
        plugins {
          id 'org.jetbrains.kotlin.jvm' version '2.1.0'
        }
      GRADLE

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "gradle --no-daemon testClasses" ])
    end

    it "reuses Java Maven prepare commands for Kotlin Maven projects" do
      write("pom.xml", "<project />\n")
      write("src/main/kotlin/example/App.kt")
      write("mvnw")

      expect(described_class.prepare_commands(@dir)).to eq([ "./mvnw -B test-compile" ])
    end

    it "declares the shared JVM mise version file" do
      expect(described_class.mise_version_file).to eq(".java-version")
    end

    it "reuses Java span labels for JVM command diagnostics" do
      labels = described_class.span_labels

      expect(labels.find { |(pattern, _)| pattern.match?("./gradlew --no-daemon test") }.last).to eq("gradle")
      expect(labels.find { |(pattern, _)| pattern.match?("java -version") }.last).to eq("java version")
    end

    it "does not claim Kotlin Multiplatform projects" do
      write("build.gradle.kts", <<~GRADLE)
        plugins {
          kotlin("multiplatform") version "2.1.0"
        }
      GRADLE
      write("src/commonMain/kotlin/example/Shared.kt")

      expect(described_class.detect?(@dir)).to be false
    end
  end

  describe Kotlin::PromptContext do
    it "returns Kotlin/JVM, Gradle wrapper, and out-of-scope guidance" do
      text = described_class.call(repository: nil, job: nil)

      expect(text).to include("Kotlin/JVM")
      expect(text).to include("build.gradle.kts")
      expect(text).to include("./gradlew")
      expect(text).to include("Multiplatform")
      expect(text).to include("mobile platform Gradle")
    end
  end

  describe Kotlin::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-kotlin-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns [] for a repo with no recognized Kotlin/JVM signal" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes Kotlin/JVM review criteria when Kotlin is detected" do
      write("src/main/kotlin/example/App.kt", "fun main() = Unit\n")

      expect(described_class.criteria(@dir)).to eq([
        "Flag swallowed CancellationException or broad coroutine exception handling that prevents cooperative cancellation",
        "Flag unsafe Kotlin null assertions (`!!`) on data from external boundaries"
      ])
    end
  end

  describe "Java Gradle grader reuse" do
    def matches_scope?(patterns, path)
      patterns.any? { |pattern| File.fnmatch(pattern, path, File::FNM_DOTMATCH) }
    end

    it "runs Kotlin/JVM Gradle tests through the shared Java Gradle grader machinery" do
      Dir.mktmpdir("syrus-kotlin-gradle-grader") do |dir|
        FileUtils.mkdir_p(File.join(dir, "build/test-results/test"))
        FileUtils.mkdir_p(File.join(dir, "src/main/kotlin/example"))
        File.write(File.join(dir, "build.gradle.kts"), "plugins { kotlin(\"jvm\") version \"2.1.0\" }\n")
        File.write(File.join(dir, "src/main/kotlin/example/App.kt"), "fun main() = Unit\n")
        File.write(File.join(dir, "build/test-results/test/TEST-example.xml"), <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <testsuite name="ExampleKtTest" tests="1">
            <testcase classname="ExampleKtTest" name="passes"/>
          </testsuite>
        XML
        File.write(File.join(dir, "gradlew"), "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, File.join(dir, "gradlew"))

        step = Java::GradleGraderType.grade_steps(config: {}, default_failures: "strict").first
        _stdout, stderr, status = Open3.capture3("bash", "-c", step.run, chdir: dir)

        expect(status).to be_success, stderr
        expect(matches_scope?(step.when_files_changed, "src/main/kotlin/example/App.kt")).to be(true)
        output = File.read(File.join(dir, ".syrus/grade-output/gradle-test-junit.xml"))
        expect(output).to include("<testsuites>")
        expect(output).to include("<testsuite name=\"ExampleKtTest\"")
      end
    end
  end
end
