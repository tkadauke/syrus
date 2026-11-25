# Solid Cable's listener is the one thread per web process that polls the
# cable database and pushes new messages to every open WebSocket. On a
# connection error it retries `reconnect_attempts` times -- by default once,
# immediately -- and then the thread exits for good. Nothing restarts it, so
# after a database restart of more than a moment the web process keeps
# serving pages but never delivers another live update until it is
# restarted. That happened in production: a MySQL restart silently froze
# chat, pending actions and the dashboard for every user.
#
# Keep reconnecting for as long as the process lives, backing off to a
# capped delay, and say so in the log.
module SolidCableListenerReconnect
  MAX_RECONNECT_DELAY = 30 # seconds

  def self.delay_for(attempt)
    [ 2**[ attempt - 1, 5 ].min, MAX_RECONNECT_DELAY ].min
  end

  private

  def retry_connecting?
    self.reconnect_attempt += 1
    delay = SolidCableListenerReconnect.delay_for(reconnect_attempt)
    Rails.logger.warn(
      "[SolidCable] listener lost its database connection; reconnect attempt #{reconnect_attempt} in #{delay}s"
    )
    sleep(delay)
    true
  end
end

Rails.application.config.after_initialize do
  require "action_cable/subscription_adapter/solid_cable"
  ActionCable::SubscriptionAdapter::SolidCable::Listener.prepend(SolidCableListenerReconnect)
end
