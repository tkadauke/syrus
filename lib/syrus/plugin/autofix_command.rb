module Syrus
  module Plugin
    # Interface for `:autofix_command` extension points. Plugin gems implement
    # this interface to tell Steps::Format which deterministic formatter/linter
    # -a command to run in the workspace after the agentic step (implement/
    # respond) and before the grader retry loop's check phase, so a style-only
    # grader failure the tool could have fixed for free doesn't cost the agent
    # a full turn to notice and fix by hand. Only consulted as a fallback when
    # the repo's `.syrus.yml` has no explicit `formatters:` key — see
    # Steps::Format.
    #
    # Implementations must define:
    #
    #   autofix_command(workspace_path:) -> String | nil
    #     Return the shell command to run, or nil when this plugin's fixer
    #     does not apply to the repo (e.g. no config file for the tool).
    #     Each provider should return AT MOST ONE command — a plugin that
    #     offers more than one distinct fixer (e.g. ESLint and Prettier)
    #     registers one provider class per fixer instead of concatenating
    #     commands, matching the :grader_augmentor precedent.
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     provides: { autofix_command: MyPlugin::AutofixCommand }
    #   )
    module AutofixCommand
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def autofix_command(workspace_path:)
          raise NotImplementedError, "#{self}.autofix_command is required"
        end
      end

      def autofix_command(workspace_path:)
        raise NotImplementedError, "#{self.class}#autofix_command is required"
      end
    end
  end
end
