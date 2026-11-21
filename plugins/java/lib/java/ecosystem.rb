module Java
  class Ecosystem
    class << self
      def key = :java
      def display_name = "Java"

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

      def review_criteria(context) = context.repo_path ? ReviewCriteriaProvider.criteria(context.repo_path) : []

      def prompt_context(context)
        return nil unless context.repository || context.job

        PromptContext.call(repository: context.repository, job: context.job)
      end
    end
  end

  class GradleEcosystem
    class << self
      def key = :gradle
      def display_name = "Gradle"
      def grader_types(context)
        return nil if context.config.nil?

        GradleGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end

  class MavenEcosystem
    class << self
      def key = :maven
      def display_name = "Maven"
      def grader_types(context)
        return nil if context.config.nil?

        MavenGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end
end
