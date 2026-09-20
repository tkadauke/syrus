require "open3"
require "timeout"

# Best-effort self-heal for BuildCache::CacheMismatchDetector.
#
# sccache's server only reads its backend config (SCCACHE_BUCKET and
# friends) and SCCACHE_BASEDIRS once, at startup -- BuildCache::DaemonAddress
# derives a distinct port per Workflow specifically so each Workflow's first
# compiler invocation lazily spawns its own, correctly-configured daemon.
# That isolation can still be defeated in ways no port scheme fully
# closes: an overlapping Workflow whose derived port happens to collide
# (DaemonAddress's own accepted, "negligible" risk), or any subprocess
# outside Steps::Prepare/Steps::Grader's env-building path (an agentic tool
# call, say) that invokes the compiler masquerade before this Workflow's own
# prepare/grader step ever runs -- either way, once a daemon is already
# listening on this Workflow's derived port with stale/absent config,
# nothing short of stopping it makes a difference; the next compiler
# invocation lazily starts a fresh daemon that inherits the *current* env.
#
# `env` must be the exact env the mismatched command ran with, so
# `--stop-server` targets the daemon on that Workflow's own
# SCCACHE_SERVER_PORT rather than sccache's default port.
module BuildCache
  class DaemonRestarter
    TIMEOUT_SECONDS = 10

    class << self
      # Returns true when the stop command completed successfully, false
      # otherwise (sccache not on PATH, timed out, or a non-zero exit --
      # e.g. no server was listening to stop in the first place). Never
      # raises; the caller (CacheMismatchDetector) is already best-effort.
      def restart!(env:)
        _out, status = Timeout.timeout(TIMEOUT_SECONDS) do
          Open3.capture2e(env, "sccache", "--stop-server")
        end
        status.success?
      rescue Errno::ENOENT
        false # sccache not on PATH -- not every worker image build has it
      rescue Timeout::Error => e
        Rails.logger.warn("[BuildCache::DaemonRestarter] #{e.class}: #{e.message}")
        false
      end
    end
  end
end
