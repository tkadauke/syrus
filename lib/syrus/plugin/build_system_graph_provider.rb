module Syrus
  module Plugin
    # Interface for `:build_system_graph_provider` extension points. Providers
    # import explicit TargetGraph nodes from external build-system metadata
    # (Bazel/Buck/Pants/etc.) only when a repository declares them under
    # `.syrus.yml` `target_graph.imports`.
    #
    # Implementations must define:
    #
    #   provider_key -> String
    #     Stable key used by `.syrus.yml`, e.g. "bazel".
    #
    #   import_target_graph(repo_path:, config:) -> TargetGraph::Import
    #     Read the checked-out repository and return projects/targets to merge
    #     into the TargetGraph. `config` is the repo-authored import block's
    #     free-form `config:`/`options:` mapping. Do not infer structure unless
    #     the repository explicitly opted into this provider.
    module BuildSystemGraphProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def provider_key
          raise NotImplementedError, "#{self}.provider_key is required"
        end

        def import_target_graph(repo_path:, config:)
          raise NotImplementedError, "#{self}.import_target_graph is required"
        end
      end

      def provider_key
        raise NotImplementedError, "#{self.class}#provider_key is required"
      end

      def import_target_graph(repo_path:, config:)
        raise NotImplementedError, "#{self.class}#import_target_graph is required"
      end
    end
  end
end
