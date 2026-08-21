module Syrus
  module Plugin
    # Interface for `:affected_test_analyzer` extension points. Plugin gems
    # implement this interface to compute a more precise "which files does
    # this diff actually affect" set than `Steps::GraderFanout`'s
    # `when_files_changed` glob matching can — using real import/dependency
    # graph analysis for the language instead of guessing from path patterns.
    #
    # Implementations must define:
    #
    #   affected_files(repo_path:, changed_files:) -> Array<String> | nil
    #     Given the repo checkout path and the PR diff's changed files
    #     (repo-relative paths), return additional repo-relative paths that
    #     are transitively affected by the diff (e.g. spec files that
    #     exercise a changed source file via require/import edges), or `nil`
    #     to decline — when this analyzer can't confidently resolve the
    #     diff (unsupported file types, a dependency graph too large/stale
    #     to trust, an unexpected repo layout). Must not raise; catch
    #     internally and return `nil` on unexpected error.
    #
    # `Steps::GraderFanout` only ever ADDS a provider's result to the
    # diff's changed-file set before matching graders' `when_files_changed`
    # patterns against it — it never removes files the raw diff already
    # reported. That makes a provider's answer strictly additive: a
    # confident answer can turn a would-be skip into a run (catching a
    # transitively-affected grader glob matching would miss), but neither a
    # declined answer nor a raised error can ever cause a grader that would
    # have run under glob-only matching to be skipped. When no
    # `:affected_test_analyzer` is registered at all, or every registered
    # provider declines/errors, behavior is identical to glob-only matching.
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     provides: { affected_test_analyzer: MyPlugin::AffectedTestAnalyzer }
    #   )
    module AffectedTestAnalyzer
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def affected_files(repo_path:, changed_files:)
          raise NotImplementedError, "#{self}.affected_files is required"
        end
      end

      def affected_files(repo_path:, changed_files:)
        raise NotImplementedError, "#{self.class}#affected_files is required"
      end
    end
  end
end
