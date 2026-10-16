require "socket"

module Terminal
  class OrphanReaper
    STARTUP_GRACE_PERIOD = 1.minute
    CONNECT_TIMEOUT_SECONDS = 0.25
    BATCH_LIMIT = 100

    def self.run! = new.run!

    def run!
      Terminal::Session.running.order(:started_at, :id).limit(BATCH_LIMIT).each do |session|
        reap!(session) if orphaned?(session)
      end
    end

    private

    def orphaned?(session)
      return session.relay_started_at.present? && session.relay_started_at < STARTUP_GRACE_PERIOD.ago unless session.relay_ready?

      host, port = session.relay_address.split(":", 2)
      Socket.tcp(host, Integer(port), connect_timeout: CONNECT_TIMEOUT_SECONDS, &:close)
      false
    rescue ArgumentError, SocketError, IOError, SystemCallError
      true
    end

    def reap!(session)
      scope = Terminal::Session.running.where(id: session.id)
      scope = session.relay_ready? ? scope.where(relay_address: session.relay_address) : scope.where(relay_address: [ nil, "" ])
      scope.update_all(finished_at: Time.current, outcome: "orphaned")
    end
  end
end
