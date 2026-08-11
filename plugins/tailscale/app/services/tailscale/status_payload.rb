module Tailscale
  class StatusPayload
    def self.call
      new.call
    end

    def call
      daemon_running = DaemonManager.instance.alive?
      status = daemon_running ? fetch_status : nil
      hostname = status&.dig("Self", "DNSName")&.delete_suffix(".").presence

      {
        daemon_running: daemon_running,
        connected: connected?(status),
        hostname: hostname,
        tailscale_url: hostname ? "https://#{hostname}" : nil,
        auth_key_present: ENV["TS_AUTHKEY"].present?,
        net_admin_capable: File.exist?("/dev/net/tun")
      }
    end

    private

    def connected?(status)
      return false if status.blank?

      status["BackendState"] == "Running" || status.dig("Self", "Online") == true
    end

    def fetch_status
      JSON.parse(fetch_status_body)
    rescue StandardError => e
      Rails.logger.warn("[Tailscale::StatusPayload] status fetch failed: #{e.message}")
      nil
    end

    def fetch_status_body
      UNIXSocket.open(DaemonManager::SOCKET_PATH) do |sock|
        sock.write("GET /localapi/v0/status HTTP/1.0\r\nHost: local\r\n\r\n")
        sock.flush
        response = sock.read
        response.split("\r\n\r\n", 2).last || ""
      end
    end
  end
end
