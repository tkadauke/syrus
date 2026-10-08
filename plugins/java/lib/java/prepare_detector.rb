module Java
  # :prepare_detector for generic JVM repositories. Build-tool signals provide
  # concrete prepare commands; conventional source paths make the repository
  # detectable without guessing how to install dependencies.
  class PrepareDetector
    GRADLE_FILES = %w[
      build.gradle
      build.gradle.kts
      settings.gradle
      settings.gradle.kts
      gradlew
    ].freeze

    MAVEN_FILES = %w[
      pom.xml
      mvnw
      .mvn/wrapper/maven-wrapper.properties
    ].freeze

    SOURCE_PATHS = %w[
      src/main/java
      src/test/java
    ].freeze

    ANDROID_MANIFEST_PATHS = %w[
      AndroidManifest.xml
      app/src/main/AndroidManifest.xml
      src/main/AndroidManifest.xml
    ].freeze

    ANDROID_GRADLE_PLUGIN_PATTERNS = [
      /com\.android\.(?:application|library|test|dynamic-feature|asset-pack)/,
      /com\.android\.tools\.build:gradle/
    ].freeze

    ANDROID_GRADLE_FILE_GLOBS = %w[
      build.gradle
      build.gradle.kts
      settings.gradle
      settings.gradle.kts
      */build.gradle
      */build.gradle.kts
    ].freeze

    def self.detect?(repo_path)
      path = Pathname.new(repo_path)
      return false if android_project?(path)

      (GRADLE_FILES + MAVEN_FILES + SOURCE_PATHS).any? { |entry| path.join(entry).exist? }
    end

    def self.prepare_commands(repo_path)
      path = Pathname.new(repo_path)
      return [] if android_project?(path)

      if gradle_project?(path)
        [ gradle_command(path) ]
      elsif maven_project?(path)
        [ maven_command(path) ]
      else
        []
      end
    end

    def self.mise_version_file
      ".java-version"
    end

    SPAN_LABELS = [
      [ /\b(?:\.\/)?gradlew?\b.*\b(?:testClasses|test|check|build)\b/, "gradle" ],
      [ /\b(?:\.\/)?mvnw?\b.*\b(?:test-compile|test|verify|package)\b/, "maven" ],
      [ /\bjava\s+-version\b/, "java version" ],
      [ /\bjavac\b/, "javac" ]
    ].freeze

    def self.span_labels
      SPAN_LABELS
    end

    def self.gradle_project?(path)
      GRADLE_FILES.any? { |entry| path.join(entry).exist? }
    end
    private_class_method :gradle_project?

    def self.android_project?(path)
      ANDROID_MANIFEST_PATHS.any? { |entry| path.join(entry).exist? } ||
        gradle_files(path).any? { |file| android_gradle_plugin?(file) }
    end
    private_class_method :android_project?

    def self.gradle_files(path)
      ANDROID_GRADLE_FILE_GLOBS.flat_map do |pattern|
        Dir.glob(path.join(pattern).to_s).map { |file| Pathname.new(file) }
      end
    end
    private_class_method :gradle_files

    def self.android_gradle_plugin?(file)
      contents = file.read

      ANDROID_GRADLE_PLUGIN_PATTERNS.any? { |pattern| contents.match?(pattern) }
    end
    private_class_method :android_gradle_plugin?

    def self.maven_project?(path)
      MAVEN_FILES.any? { |entry| path.join(entry).exist? }
    end
    private_class_method :maven_project?

    def self.gradle_command(path)
      executable = path.join("gradlew").exist? ? "./gradlew" : "gradle"

      "#{executable} --no-daemon testClasses"
    end
    private_class_method :gradle_command

    def self.maven_command(path)
      executable = path.join("mvnw").exist? ? "./mvnw" : "mvn"

      "#{executable} -B test-compile"
    end
    private_class_method :maven_command
  end
end
