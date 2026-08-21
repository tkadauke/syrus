module Syrus
  module Plugin
    # Interface for `:review_criteria_provider` extension points. Plugin gems
    # implement this interface to contribute default per-language adversarial
    # review checklist items — reviewer prompt guidance that applies without
    # requiring the operator to configure `.syrus.yml`'s
    # `adversarial_review.criteria`.
    #
    # Implementations must define:
    #
    #   criteria(repo_path) -> Array<String>
    #     Return checklist strings to add to the reviewer prompt when this
    #     plugin's ecosystem is present in the repo, or [] when it isn't (or
    #     the plugin has nothing to add). Must not raise.
    #
    # Contributed criteria are additive: they concatenate with any criteria
    # `.syrus.yml` declares under `adversarial_review.criteria`, and with
    # every other registered provider's criteria. There is no override
    # mechanism — an empty array is the only way to contribute nothing.
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     provides: { review_criteria_provider: MyPlugin::ReviewCriteriaProvider }
    #   )
    module ReviewCriteriaProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def criteria(repo_path)
          raise NotImplementedError, "#{self}.criteria is required"
        end
      end

      def criteria(repo_path)
        raise NotImplementedError, "#{self.class}#criteria is required"
      end
    end
  end
end
