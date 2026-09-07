module Terminal
  # Shared write path for terminating a session: flips it to
  # finished/killed so the worker-side Relay's kill-poll (every
  # KILL_POLL_INTERVAL_SECONDS) observes `finished_at` and sends
  # SIGTERM to the PTY. Used by both the user-scoped app API and the
  # admin API so there is exactly one place that knows how a kill
  # is recorded.
  class KillSession
    def self.call(session)
      new(session).call
    end

    def initialize(session)
      @session = session
    end

    def call
      @session.update!(finished_at: Time.current, outcome: "killed") if @session.running?
      @session
    end
  end
end
