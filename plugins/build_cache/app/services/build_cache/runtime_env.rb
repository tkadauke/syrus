# Computed (not merely forwarded) env additions for prepare/grader
# subprocesses. This is the companion to StepEnvironment#forwarded_env_keys
# for values that don't already sit in the worker pod's own ENV --
# SCCACHE_SERVER_PORT is derived per Workflow (see DaemonAddress), and
# SCCACHE_BASEDIRS is derived from the workspace path itself, only for
# repositories that have proven their coverage build is path-remapped/safe
# under normalization (see RepositorySettings, config/syrus_docs/sccache_build_cache.md's
# "Cache-safe coverage recipe"). Every other repository gets no
# SCCACHE_BASEDIRS at all, preserving sccache's default exact-path-match
# behavior that keeps gcov/--coverage cache hits scoped to the same
# still-live Workflow workspace.
module BuildCache
  module RuntimeEnv
    def self.for(workflow:, workspace_path:)
      env = { "SCCACHE_SERVER_PORT" => DaemonAddress.port_for(workflow).to_s }
      env["SCCACHE_BASEDIRS"] = workspace_path.to_s if basedirs_safe?(workflow)
      env
    end

    def self.basedirs_safe?(workflow)
      repository = workflow.job&.repository
      return false unless repository

      RepositorySettings.basedirs_safe_for?(repository)
    end
  end
end
