module BuildCache
  class StepEnvironment
    include Syrus::Plugin::StepEnvironment

    # sccache is masqueraded onto PATH as cc/gcc/g++/clang in the worker image
    # (Dockerfile, worker-deps stage); these are the env vars its S3 backend
    # reads to reach the shared bucket instead of falling back to a useless
    # per-invocation local cache. An unset SCCACHE_BUCKET is a supported no-op.
    #
    # SCCACHE_BASEDIRS is deliberately absent. sccache's default -- require an
    # exact absolute-path match to hit cache -- is what keeps gcov/--coverage
    # builds correct: every Workflow clones to a unique, never-reused path, so
    # a gcov-instrumented compile's .gcno notes file (which sccache restores
    # byte-for-byte, embedded absolute source paths and all) can only hit
    # against the same workflow's still-live workspace. Forwarding
    # SCCACHE_BASEDIRS would normalize those paths before hashing and let a
    # coverage build hit across workflows, silently corrupting gcovr output
    # with a .gcno pointing at a different, likely-deleted workspace.
    # See config/syrus_docs/sccache_build_cache.md.
    KEYS = %w[
      SCCACHE_BUCKET SCCACHE_ENDPOINT SCCACHE_REGION SCCACHE_S3_KEY_PREFIX
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    ].freeze

    def self.forwarded_env_keys = KEYS
  end
end
