module Kotlin
  class Ecosystem
    class << self
      def key = :kotlin
      def display_name = "Kotlin"

      def detect_prepare(context)
        return [] unless context.repo_path && PrepareDetector.detect?(context.repo_path)

        java_plan = java_provider(:detect_prepare)&.invoke do |provider|
          Array(provider.detect_prepare(context)).first
        end
        [ Syrus::Host::EcosystemPreparePlan.new(
          detected: true,
          commands: java_plan&.commands || [],
          version_file: java_plan&.version_file || ".java-version",
          span_labels: java_plan&.span_labels || [],
          label: display_name
        ) ]
      end

      def review_criteria(context) = context.repo_path ? ReviewCriteriaProvider.criteria(context.repo_path) : []

      def prompt_context(context)
        return nil unless context.repository || context.job

        PromptContext.call(repository: context.repository, job: context.job)
      end

      private

      def java_provider(capability)
        Syrus::Host::PluginRegistry.capability_providers(:ecosystem, capability)
          .find { |provider| provider.plugin_name == "java" }
      end
    end
  end
end
