module Ios
  # :prepare_detector for iOS and Swift repositories. SwiftPM has a safe
  # scheme-free dependency resolution command; Xcode projects usually need an
  # operator-chosen workspace/project plus scheme, so those prepare commands
  # stay explicit in `.syrus.yml`.
  class PrepareDetector
    XCODE_GLOBS = %w[
      *.xcodeproj
      *.xcworkspace
      */*.xcodeproj
      */*.xcworkspace
    ].freeze

    SWIFT_SOURCE_GLOBS = %w[
      *.swift
      Sources/**/*.swift
      Tests/**/*.swift
      */Sources/**/*.swift
      */Tests/**/*.swift
    ].freeze

    def self.detect?(repo_path)
      path = Pathname.new(repo_path)
      path.join("Package.swift").exist? ||
        any_entry_matching?(path, XCODE_GLOBS) ||
        any_file_matching?(path, SWIFT_SOURCE_GLOBS)
    end

    def self.prepare_commands(repo_path)
      path = Pathname.new(repo_path)
      return [ "swift package resolve" ] if path.join("Package.swift").exist?

      []
    end

    SPAN_LABELS = [
      [ /\bxcodebuild\b.*\b(?:test|build|archive|-resolvePackageDependencies)\b/, "xcodebuild" ],
      [ /\bswift\s+(?:test|build|package\s+resolve)\b/, "swift package" ]
    ].freeze

    def self.span_labels
      SPAN_LABELS
    end

    def self.any_entry_matching?(path, patterns)
      patterns.any? { |pattern| Dir.glob(path.join(pattern).to_s).any? { |entry| File.exist?(entry) } }
    end
    private_class_method :any_entry_matching?

    def self.any_file_matching?(path, patterns)
      patterns.any? { |pattern| Dir.glob(path.join(pattern).to_s).any? { |entry| File.file?(entry) } }
    end
    private_class_method :any_file_matching?
  end
end
