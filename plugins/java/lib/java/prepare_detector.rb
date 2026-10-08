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

    def self.detect?(repo_path)
      path = Pathname.new(repo_path)

      (GRADLE_FILES + MAVEN_FILES + SOURCE_PATHS).any? { |entry| path.join(entry).exist? }
    end

    def self.prepare_commands(repo_path)
      path = Pathname.new(repo_path)

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
