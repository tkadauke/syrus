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
    module StepEnvironment
    end
  end
end
