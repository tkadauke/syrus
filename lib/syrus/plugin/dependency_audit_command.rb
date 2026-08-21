module Syrus
  module Plugin
    # Interface for `:dependency_audit_command` extension points. Plugin gems
    # implement this interface to tell Steps::DependencyAudit which shell
    # command scans this ecosystem's dependencies for known vulnerabilities,
    # and which lockfile(s) in a PR diff should trigger that scan.
    #
    # Implementations must define:
    #
    #   lockfiles -> Array<String>
    #     Basenames of the lockfile(s) this plugin's audit command applies
    #     to (e.g. Ruby's `Gemfile.lock`, Go's `go.sum`). Steps::DependencyAudit
    #     matches these against the PR diff's changed files (by basename) to
    #     decide whether to run this provider's audit command at all — a repo
    #     whose diff never touches one of these files skips the scan entirely.
    #
    #   audit_command(workspace_path:) -> String | nil
    #     Return the shell command to run, or nil when this plugin's audit
    #     tool does not apply to the repo (e.g. none of `lockfiles` actually
    #     exist on disk, or the ecosystem needs a different tool than usual
    #     for the lockfile that's present). Each provider should return AT
    #     MOST ONE command — a plugin whose ecosystem has more than one
    #     distinct audit tool registers one provider class per tool, the
    #     same multi-provider pattern `:grader_augmentor`/`:autofix_command`
    #     use.
    #
    # A non-zero exit status from the returned command is NOT a tool error —
    # it is how bundler-audit/npm audit/pip-audit/govulncheck report that
    # vulnerabilities were found. Steps::DependencyAudit treats exit 0 as a
    # clean scan and any non-zero exit as "surface this output," never as a
    # step or grader failure.
    #
    # Register an implementation at boot time:
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     provides: { dependency_audit_command: MyPlugin::DependencyAuditCommand }
    #   )
    module DependencyAuditCommand
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def lockfiles
          raise NotImplementedError, "#{self}.lockfiles is required"
        end

        def audit_command(workspace_path:)
          raise NotImplementedError, "#{self}.audit_command is required"
        end
      end

      def lockfiles
        raise NotImplementedError, "#{self.class}#lockfiles is required"
      end

      def audit_command(workspace_path:)
        raise NotImplementedError, "#{self.class}#audit_command is required"
      end
    end
  end
end
