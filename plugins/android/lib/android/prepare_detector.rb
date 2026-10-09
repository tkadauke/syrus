module Android
  # :prepare_detector for Android repositories. It claims Android-specific
  # project signals that the generic Java/Kotlin detectors intentionally skip,
  # while avoiding SDK/emulator commands until those capabilities are present.
  class PrepareDetector
    ANDROID_MANIFEST_GLOBS = %w[
      AndroidManifest.xml
      */AndroidManifest.xml
      src/main/AndroidManifest.xml
      */src/main/AndroidManifest.xml
      */*/src/main/AndroidManifest.xml
    ].freeze

    ANDROID_SOURCE_PATH_GLOBS = %w[
      src/main/res
      */src/main/res
      */*/src/main/res
      src/androidTest
      */src/androidTest
      */*/src/androidTest
    ].freeze

    GRADLE_FILE_GLOBS = %w[
      build.gradle
      build.gradle.kts
      settings.gradle
      settings.gradle.kts
      */build.gradle
      */build.gradle.kts
    ].freeze

    ANDROID_GRADLE_PLUGIN_PATTERNS = [
      /com\.android\.(?:application|library|test|dynamic-feature|asset-pack)/,
      /com\.android\.tools\.build:gradle/,
      /kotlin\(["']android["']\)/,
      /org\.jetbrains\.kotlin\.android/
    ].freeze

    SPAN_LABELS = [
      [
        /(?:^|\s)(?:\.\/)?gradlew?\b.*\b(?:assemble\w*|bundle\w*|connected\w*|test.*UnitTest|lint\w*)\b/i,
        "android gradle"
      ],
      [ /\badb\b/, "adb" ],
      [ /\bemulator\b/, "android emulator" ],
      [ /\bsdkmanager\b/, "android sdkmanager" ],
      [ /\bavdmanager\b/, "android avdmanager" ]
    ].freeze

    def self.detect?(repo_path)
      path = Pathname.new(repo_path)

      android_manifest?(path) || android_source_path?(path) || android_gradle_plugin?(path)
    end

    def self.prepare_commands(_repo_path)
      []
    end

    def self.mise_version_file
      Java::PrepareDetector.mise_version_file
    end

    def self.span_labels
      Java::PrepareDetector.span_labels + SPAN_LABELS
    end

    def self.android_manifest?(path)
      ANDROID_MANIFEST_GLOBS.any? { |pattern| any_file_matching?(path, pattern) }
    end
    private_class_method :android_manifest?

    def self.android_source_path?(path)
      ANDROID_SOURCE_PATH_GLOBS.any? do |pattern|
        Dir.glob(path.join(pattern).to_s, File::FNM_DOTMATCH).any? { |entry| File.directory?(entry) }
      end
    end
    private_class_method :android_source_path?

    def self.android_gradle_plugin?(path)
      gradle_files(path).any? do |file|
        contents = file.read
        ANDROID_GRADLE_PLUGIN_PATTERNS.any? { |pattern| contents.match?(pattern) }
      end
    end
    private_class_method :android_gradle_plugin?

    def self.gradle_files(path)
      GRADLE_FILE_GLOBS.flat_map do |pattern|
        Dir.glob(path.join(pattern).to_s).map { |file| Pathname.new(file) }
      end
    end
    private_class_method :gradle_files

    def self.any_file_matching?(path, pattern)
      Dir.glob(path.join(pattern).to_s, File::FNM_DOTMATCH).any? { |file| File.file?(file) }
    end
    private_class_method :any_file_matching?
  end
end
