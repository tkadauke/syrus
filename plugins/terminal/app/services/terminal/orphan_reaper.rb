require "socket"

module Terminal
  class OrphanReaper
    STARTUP_GRACE_PERIOD = 1.minute
    CONNECT_TIMEOUT_SECONDS = 0.25
    BATCH_LIMIT = 100

    def self.run! = new.run!

    def run!
      Terminal::Session.running.order(:started_at, :id).limit(BATCH_LIMIT).each do |session|
        next unless orphaned?(session)

        Terminal::Session.running.where(id: session.id).update_all(
          finished_at: Time.current,
          outcome: "orphaned"
        )
      end
    end

    private

    def orphaned?(session)
      return session.started_at < STARTUP_GRACE_PERIOD.ago unless session.relay_ready?

      host, port = session.relay_address.split(":", 2)
      Socket.tcp(host, Integer(port), connect_timeout: CONNECT_TIMEOUT_SECONDS, &:close)
      false
    rescue ArgumentError, SocketError, IOError, SystemCallError
      true
    end
  end
end
