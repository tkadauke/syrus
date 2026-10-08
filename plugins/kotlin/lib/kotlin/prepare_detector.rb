module Kotlin
  # :prepare_detector for Kotlin/JVM repositories. It recognizes Kotlin source
  # and Gradle Kotlin DSL signals, then delegates concrete build setup to the
  # Java plugin's wrapper-aware Gradle/Maven prepare detector.
  class PrepareDetector
    KOTLIN_SOURCE_PATHS = %w[
      src/main/kotlin
      src/test/kotlin
    ].freeze

    KOTLIN_FILE_GLOBS = %w[
      *.kt
      *.kts
      **/*.kt
      **/*.kts
    ].freeze

    GRADLE_KOTLIN_DSL_FILES = %w[
      build.gradle.kts
      settings.gradle.kts
    ].freeze

    GRADLE_FILE_GLOBS = %w[
      build.gradle
      build.gradle.kts
      settings.gradle
      settings.gradle.kts
      */build.gradle
      */build.gradle.kts
    ].freeze

    KOTLIN_JVM_PLUGIN_PATTERNS = [
      /org\.jetbrains\.kotlin\.jvm/,
      /kotlin\(["']jvm["']\)/
    ].freeze

    OUT_OF_SCOPE_PLUGIN_PATTERNS = [
      /com\.android\.(?:application|library|test|dynamic-feature|asset-pack)/,
      /com\.android\.tools\.build:gradle/,
      /org\.jetbrains\.kotlin\.android/,
      /kotlin\(["']android["']\)/,
      /org\.jetbrains\.kotlin\.multiplatform/,
      /kotlin\(["']multiplatform["']\)/,
      /org\.jetbrains\.kotlin\.native/
    ].freeze

    ANDROID_MANIFEST_PATHS = %w[
      AndroidManifest.xml
      app/src/main/AndroidManifest.xml
      src/main/AndroidManifest.xml
    ].freeze

    def self.detect?(repo_path)
      path = Pathname.new(repo_path)
      return false if out_of_scope_project?(path)

      kotlin_source_path?(path) ||
        gradle_kotlin_dsl_file?(path) ||
        kotlin_file?(path) ||
        kotlin_jvm_gradle_plugin?(path)
    end

    def self.prepare_commands(repo_path)
      return [] unless detect?(repo_path)

      Java::PrepareDetector.prepare_commands(repo_path)
    end

    def self.mise_version_file
      Java::PrepareDetector.mise_version_file
    end

    def self.span_labels
      Java::PrepareDetector.span_labels
    end

    def self.kotlin_source_path?(path)
      KOTLIN_SOURCE_PATHS.any? { |entry| path.join(entry).exist? }
    end
    private_class_method :kotlin_source_path?

    def self.gradle_kotlin_dsl_file?(path)
      GRADLE_KOTLIN_DSL_FILES.any? { |entry| path.join(entry).exist? }
    end
    private_class_method :gradle_kotlin_dsl_file?

    def self.kotlin_file?(path)
      KOTLIN_FILE_GLOBS.any? { |pattern| any_file_matching?(path, pattern) }
    end
    private_class_method :kotlin_file?

    def self.any_file_matching?(path, pattern)
      Dir.glob(path.join(pattern).to_s, File::FNM_DOTMATCH).any? { |file| File.file?(file) }
    end
    private_class_method :any_file_matching?

    def self.kotlin_jvm_gradle_plugin?(path)
      gradle_files(path).any? do |file|
        contents = file.read
        KOTLIN_JVM_PLUGIN_PATTERNS.any? { |pattern| contents.match?(pattern) }
      end
    end
    private_class_method :kotlin_jvm_gradle_plugin?

    def self.out_of_scope_project?(path)
      ANDROID_MANIFEST_PATHS.any? { |entry| path.join(entry).exist? } ||
        gradle_files(path).any? { |file| out_of_scope_gradle_plugin?(file) }
    end
    private_class_method :out_of_scope_project?

    def self.gradle_files(path)
      GRADLE_FILE_GLOBS.flat_map do |pattern|
        Dir.glob(path.join(pattern).to_s).map { |file| Pathname.new(file) }
      end
    end
    private_class_method :gradle_files

    def self.out_of_scope_gradle_plugin?(file)
      contents = file.read

      OUT_OF_SCOPE_PLUGIN_PATTERNS.any? { |pattern| contents.match?(pattern) }
    end
    private_class_method :out_of_scope_gradle_plugin?
  end
end
