module Syrus
  module Plugin
    # Marker interface for plugins that need environment variables forwarded
    # into the subprocesses a workflow step runs.
    #
    # Step subprocesses get a deliberately narrow, scrubbed environment so the
    # worker's own Bundler and toolchain config cannot leak into the target
    # repository. That list lived as a constant in Steps::Prepare, which meant
    # a plugin whose tooling needs configuration -- a shared compiler cache
    # reaching an S3 bucket, say -- could only be served by editing core.
    #
    # Providers return the ENV names to forward; values come from the worker's
    # own environment, never from the plugin:
    #
    #   def self.forwarded_env_keys = %w[SCCACHE_BUCKET SCCACHE_ENDPOINT]
    #
    # Returning a name that is unset in the worker environment is harmless --
    # ProcessRunner simply does not forward it.
    #
    # A provider may optionally also implement `#extra_env`, the companion
    # hook for values that don't already exist in the worker pod's own ENV --
    # a value computed per scope (a per-scope daemon port, say), rather than
    # a name to copy through:
    #
    #   def self.extra_env(scope:, workspace_path:) = { "SCCACHE_SERVER_PORT" => "20123" }
    #
    # `scope` is a PrepareScope (see app/services/prepare_scope.rb) rather
    # than a bare Workflow -- this hook runs for both workflow Steps
    # (Steps::Prepare, Steps::Grader) and Coding Mode's chat workspace
    # prepare (ChatWorkspacePrepareJob), which has a ChatSession +
    # Repository and no Workflow at all. Read `scope.id`/`scope.repository`,
    # or hash `scope.cache_key` for a stable per-scope derived value; do not
    # assume `scope` responds to Workflow-specific methods.
    #
    # `#extra_env` is optional; a provider that only forwards static names
    # from the worker environment does not need to define it.
    module StepEnvironment
    end
  end
end
