module Ios
  class Ecosystem
    class << self
      def key = :ios
      def display_name = "iOS"

      def detect_prepare(context)
        return [] unless context.repo_path && PrepareDetector.detect?(context.repo_path)

        [ Syrus::Host::EcosystemPreparePlan.new(
          detected: true,
          commands: PrepareDetector.prepare_commands(context.repo_path),
          version_file: PrepareDetector.mise_version_file,
          span_labels: PrepareDetector.span_labels,
          label: display_name
        ) ]
      end
    end
  end

  class XcodebuildEcosystem
    class << self
      def key = :xcodebuild
      def display_name = "Xcodebuild"
      def grader_types(context)
        return nil if context.config.nil?

        XcodebuildGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end

  class SwiftpmEcosystem
    class << self
      def key = :swiftpm
      def display_name = "Swift Package Manager"
      def grader_types(context)
        return nil if context.config.nil?

        SwiftpmGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end
end
