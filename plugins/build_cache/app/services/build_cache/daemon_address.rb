# Derives a stable sccache server TCP port per PrepareScope (the relevant
# change follow-up; generalized from per-Workflow to per-scope so Coding
# Mode's chat workspace prepare, which has no Workflow, gets the same
# isolation).
#
# sccache's client/server split reads its backend config (SCCACHE_BUCKET and
# friends) and SCCACHE_BASEDIRS only once, when the SERVER process starts --
# a later client invocation's env has no effect on an already-running
# server. Worker pods run multiple Workflows AND chat Coding Mode sessions
# concurrently, and a single sccache daemon on the default port is
# effectively a long-lived, host-scoped singleton: it keeps serving
# whatever env its very first invocation (on this pod, ever) happened to
# have, indefinitely, across unrelated Jobs, chat sessions, and
# repositories. That is the root cause behind the relevant change's
# captured stats showing `basedirs: []` and a local-disk `cache_location`
# despite that specific grader command's env being correct -- the daemon
# actually answering requests had already been started, by something else,
# with different env.
#
# Deriving a distinct port per scope makes each scope's first compiler
# invocation (almost always during prepare) lazily spawn its OWN daemon,
# guaranteed to inherit that scope's own, current, correct env (see
# RuntimeEnv) -- never a stale daemon left over from an earlier scope, and
# never shared with a concurrent one on the same pod.
require "zlib"

module BuildCache
  module DaemonAddress
    # Ports below this are more likely to collide with other reserved
    # services on the worker host; the span is sized well above the largest
    # realistic per-pod concurrent-scope count so two live scopes landing on
    # the same derived port is a negligible, self-healing risk (a same-port
    # collision just means two scopes share one daemon for as long as both
    # happen to overlap -- functionally the pre-fix behavior, not a crash).
    PORT_BASE = 20000
    PORT_SPAN = 40000

    # Hashes PrepareScope#cache_key (namespace + id, e.g. "workflow:42" vs
    # "chat:42") rather than the bare id, so a Workflow and a ChatSession
    # that happen to share the same numeric id derive different ports --
    # a plain `id % PORT_SPAN` would collide the two scope kinds by
    # construction instead of merely by the accepted, negligible same-kind
    # collision risk above.
    def self.port_for(scope)
      PORT_BASE + (Zlib.crc32(scope.cache_key) % PORT_SPAN)
    end
  end
end
