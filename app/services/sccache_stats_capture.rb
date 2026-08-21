require "open3"
require "timeout"

# Best-effort `sccache --show-stats --stats-format=json` snapshot (EPIC-251).
# Called by Steps::Prepare and Steps::Grader after each shell command they
# run, with the wrapper's own compiler masquerade active. Non-C/C++ repos
# (and any repo before the `sccache` binary is on PATH, e.g. local dev)
# simply have no `sccache` executable to find — that's a normal, silent
# no-op, not a failure worth surfacing to the operator.
class SccacheStatsCapture
  TIMEOUT_SECONDS = 10

  class << self
    # Returns the parsed stats Hash, or nil if sccache isn't installed,
    # times out, or returns anything other than a clean JSON success.
    def capture(env:, chdir:)
      out, status = Timeout.timeout(TIMEOUT_SECONDS) do
        Open3.capture2e(env, "sccache", "--show-stats", "--stats-format=json", chdir: chdir.to_s)
      end
      return nil unless status.success?

      JSON.parse(out)
    rescue Errno::ENOENT
      nil # sccache not on PATH — not every worker image build has it, and that's fine
    rescue Timeout::Error, JSON::ParserError => e
      Rails.logger.warn("[SccacheStatsCapture] #{e.class}: #{e.message}")
      nil
    end
  end
end
