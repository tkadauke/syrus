module Terminal
  # Admin-facing session JSON: everything ::Terminal::SessionSerializer
  # exposes to the session's own user, plus the operational fields an
  # admin needs to find and reason about a stuck session across users
  # (owning user, derived hostname, age). Never includes auth_token —
  # that stays a relay-only secret.
  #
  # Per-record resilience mirrors Admin::JobStateSerializer: a bad row
  # emits { id:, error_serializing: }  instead of 500ing the whole list.
  class AdminSessionSerializer
    def self.render(session)
      new(session).render
    end

    def initialize(session)
      @session = session
    end

    def render
      ::Terminal::SessionSerializer.render(@session).merge(
        state: @session.running? ? "running" : "finished",
        hostname: hostname,
        age_s: age_seconds,
        user: user_payload
      )
    rescue => e
      Rails.logger.warn(
        "[terminal/admin_session_serializer] failed for Terminal::Session##{@session&.id}: #{e.class}: #{e.message}"
      )
      { id: @session&.id, error_serializing: "#{e.class}: #{e.message}" }
    end

    private

    def hostname
      @session.relay_address&.split(":", 2)&.first
    end

    def age_seconds
      return nil unless @session.started_at

      reference = @session.finished_at || Time.current
      (reference - @session.started_at).round
    end

    def user_payload
      user = @session.user
      return nil unless user

      { id: user.id, email_address: user.email_address }
    end
  end
end
