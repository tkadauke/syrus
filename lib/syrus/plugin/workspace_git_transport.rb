module Syrus
  module Plugin
    # Interface for `:workspace_git_transport` extension points: plugins that
    # can hand a workflow or chat workspace a git remote to clone/fetch from
    # instead of the hosting platform, when they keep a synced local copy
    # (a mirror service being the motivating case).
    #
    # WorkflowWorkspace and ChatWorkspace (via WorkspaceGitTransportPreference)
    # consult every enabled provider through WorkspaceGitTransports and try
    # the first one available for a repository; a failed attempt, or one that
    # lands on a stale commit, falls back to the hosting platform exactly as
    # if no provider were available. Nothing in core names a particular
    # provider.
    #
    # Class methods (required):
    #
    #   available_for?(repository)  -> Boolean. Must be cheap and must not
    #                                  touch the network.
    #   build(repository:, user:)   -> a provider instance bound to that
    #                                  repository, or nil when it cannot
    #                                  serve it right now.
    #
    # Instance methods (required):
    #
    #   url    -> String, a git URL for `git clone`/`git fetch`. Must never
    #             carry a credential -- any auth this transport needs travels
    #             through #env instead, so it never lands on a command line,
    #             in `.git/config`, or in a git error message that ends up
    #             logged.
    #   env    -> Hash, extra env for the GitRunner#run call against #url
    #             (e.g. an `http.extraHeader` auth header via GIT_CONFIG_*).
    #             Merged with the caller's own env; per-call keys still win.
    #
    # Instance method (optional):
    #
    #   register!  -> Best-effort: make sure the transport actually knows
    #                 about this repository. Called once before the caller's
    #                 first attempt against #url fails, and once more after,
    #                 before the caller gives up on this provider. Default is
    #                 a no-op.
    #
    # Register an implementation at boot time:
    #   provides workspace_git_transport: "MyPlugin::Transport"
    module WorkspaceGitTransport
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def available_for?(_repository)
          raise NotImplementedError, "#{name} must implement .available_for?"
        end

        def build(repository:, user:)
          raise NotImplementedError, "#{name} must implement .build"
        end
      end

      def url
        raise NotImplementedError, "#{self.class.name} must implement #url"
      end

      def env
        {}
      end

      def register!
      end
    end
  end
end
