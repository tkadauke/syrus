require "securerandom"

module SyrusBrowser
  # Tracks which accessibility snapshot belongs to the current browser state.
  # Refs are only meaningful until navigation, interaction, or viewport change.
  module SnapshotFreshness
    MUTEX = Mutex.new
    private_constant :MUTEX

    @states = {}

    class << self
      def record(session_key)
        MUTEX.synchronize do
          state = (@states[session_key] ||= { revision: 0 })
          state[:token] = "snapshot-#{state[:revision]}-#{SecureRandom.hex(6)}"
        end
      end

      def invalidate(session_key)
        MUTEX.synchronize do
          state = (@states[session_key] ||= { revision: 0 })
          state[:revision] += 1
          state.delete(:token)
        end
      end

      def current?(session_key, token)
        MUTEX.synchronize { token.present? && @states.dig(session_key, :token) == token }
      end

      def reset!
        MUTEX.synchronize { @states.clear }
      end
    end
  end
end
