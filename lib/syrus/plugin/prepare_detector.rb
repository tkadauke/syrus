module Syrus
  module Plugin
    # Interface for `:prepare_detector` extension points. Plugin gems implement
    # this interface to tell RepoPrepPlan which shell commands to run in a
    # freshly-cloned workspace before handing off to the agent, based on
    # signals in the repo (lockfiles, config files, etc.).
    #
    # Implementations must define:
    #
    #   detect?(repo_path) -> Boolean
    #     Return true if this plugin's ecosystem is present in the repo.
    #
    #   prepare_commands(repo_path) -> Array<String>
    #     Return the commands to run. Each plugin must return AT MOST ONE
    #     command per package manager it fronts — if the repo could use more
    #     than one package manager for the same language (e.g. yarn.lock AND
    #     package-lock.json both present), pick exactly one internally instead
    #     of returning both. RepoPrepPlan unions prepare_commands across every
    #     matching plugin (cross-language), but does not dedupe within one
    #     plugin's contribution.
    #
    # Implementations may optionally define:
    #
    #   mise_version_file -> String or nil
    #     The mise version-pin filename this plugin's ecosystem owns (e.g.
    #     ".ruby-version"). Steps::Prepare treats its presence in the
    #     workspace, alongside the two universal mise triggers
    #     (.tool-versions, .mise.toml), as a signal to run `mise install`
    #     before any prepare commands. Not tied to `detect?` — the version
    #     file can be present even when the plugin's own primary signal
    #     (Gemfile, package.json, etc.) isn't. Defaults to nil (no
    #     plugin-declared version file).
    #
    #   span_labels -> Array<[Regexp, String]>
    #     Regex → human-readable label pairs for sub-commands this plugin's
    #     ecosystem owns (e.g. [[/\brspec\b/, "rspec"]]). GraderCommandSpans::Plan
    #     checks every enabled plugin's span_labels, in prepare_priority order,
    #     when labeling a grader sub-command for the live worker-health UI.
    #     Defaults to [] (no plugin-declared labels).
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     prepare_priority: 100,
    #     provides: { prepare_detector: MyPlugin::PrepareDetector }
    #   )
    #
    # `prepare_priority` (lower runs/orders first, default 100) controls the
    # order commands from different plugins are concatenated in — useful when
    # one ecosystem's setup must run before another's.
    module PrepareDetector
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def detect?(repo_path)
          raise NotImplementedError, "#{self}.detect? is required"
        end

        def prepare_commands(repo_path)
          raise NotImplementedError, "#{self}.prepare_commands is required"
        end

        def mise_version_file
          nil
        end

        def span_labels
          []
        end
      end

      def detect?(repo_path)
        raise NotImplementedError, "#{self.class}#detect? is required"
      end

      def prepare_commands(repo_path)
        raise NotImplementedError, "#{self.class}#prepare_commands is required"
      end

      def mise_version_file
        nil
      end

      def span_labels
        []
      end
    end
  end
end
