# Derives a per-Workflow sccache server TCP port (EPIC-251 follow-up).
#
# sccache's client/server split reads its backend config (SCCACHE_BUCKET and
# friends) and SCCACHE_BASEDIRS only once, when the SERVER process starts --
# a later client invocation's env has no effect on an already-running
# server. Worker pods run multiple Workflows concurrently
# (`AppSetting.max_concurrent_agent_runs`), and a single sccache daemon on
# the default port is effectively a long-lived, host-scoped singleton: it
# keeps serving whatever env its very first invocation (on this pod, ever)
# happened to have, indefinitely, across unrelated Jobs and repositories.
# That is the root cause behind JOB-4309's captured stats showing
# `basedirs: []` and a local-disk `cache_location` despite that specific
# grader command's env being correct -- the daemon actually answering
# requests had already been started, by something else, with different env.
#
# Deriving a distinct port per Workflow makes each Workflow's first
# compiler invocation (almost always during `prepare`) lazily spawn its OWN
# daemon, guaranteed to inherit that Workflow's own, current, correct env
# (see RuntimeEnv) -- never a stale daemon left over from an earlier
# Workflow, and never shared with a concurrent one on the same pod.
module BuildCache
  module DaemonAddress
    # Ports below this are more likely to collide with other reserved
    # services on the worker host; the span is sized well above the largest
    # realistic per-pod concurrent-Workflow count so two live Workflows
    # landing on the same derived port is a negligible, self-healing risk
    # (a same-port collision just means two Workflows share one daemon for
    # as long as both happen to overlap -- functionally the pre-fix
    # behavior, not a crash).
    PORT_BASE = 20000
    PORT_SPAN = 40000

    def self.port_for(workflow)
      PORT_BASE + (workflow.id % PORT_SPAN)
    end
  end
end
