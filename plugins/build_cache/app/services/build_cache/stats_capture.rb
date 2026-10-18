# Best-effort `sccache --show-stats --stats-format=json` snapshot .
# Called by Steps::Prepare and Steps::Grader after each shell command they
# run, with the wrapper's own compiler masquerade active. Non-C/C++ repos
# (and any repo before the `sccache` binary is on PATH, e.g. local dev)
# simply have no `sccache` executable to find — that's a normal, silent
# no-op, not a failure worth surfacing to the operator.
module BuildCache
  class StatsCapture
    TIMEOUT_SECONDS = 10

    class << self
      # Returns the parsed stats Hash, or nil if sccache isn't installed,
      # times out, or returns anything other than a clean JSON success.
      def capture(env:, chdir:)
        current_run = Thread.current[:syrus_current_run]
        result = ProcessRunner.new(
          env: env, command: [ "sccache", "--show-stats", "--stats-format=json" ],
          mounts: ProcessRunner.mounts(chdir), network: "grader", timeout: TIMEOUT_SECONDS,
          kind: "runtime_probe", run: current_run, workflow: current_run&.workflow
        ).capture
        return nil unless result.success?

        JSON.parse(result.stdout)
      rescue Errno::ENOENT
        nil # sccache not on PATH — not every worker image build has it, and that's fine
      rescue StandardError => e
        Rails.logger.warn("[BuildCache::StatsCapture] #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
