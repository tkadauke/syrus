module Tailscale
  class StatusPayload
    def self.call
      new.call
    end

    def call
      status = RemoteStatus.call
      hostname = status&.dig("hostname").presence

      {
        daemon_running: status.present? && status["daemon_running"] == true,
        connected: status.present? && status["connected"] == true,
        hostname: hostname,
        tailscale_url: hostname ? "https://#{hostname}" : nil,
        auth_key_present: Syrus::PluginSettings.for("tailscale").present?(:auth_key)
      }
    end
  end
end
