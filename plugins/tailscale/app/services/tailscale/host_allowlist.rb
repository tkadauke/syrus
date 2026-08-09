module Tailscale
  class HostAllowlist
    class << self
      def sync
        entries = fetch_entries
        clear

        new_entries = entries.reject { |e| hosts.include?(e) }
        hosts.concat(new_entries)
        @added_entries = new_entries
      rescue StandardError => e
        Rails.logger.warn("[Tailscale::HostAllowlist] sync failed: #{e.message}")
      end

      def clear
        return if @added_entries.blank?

        @added_entries.each { |entry| hosts.delete(entry) }
        @added_entries = []
      end

      private

      def fetch_entries
        body = fetch_status_body
        data = JSON.parse(body)

        dns_name = data.dig("Self", "DNSName")&.delete_suffix(".")
        ips = data.dig("Self", "TailscaleIPs") || []

        [dns_name, *ips].compact.reject(&:blank?)
      end

      def fetch_status_body
        UNIXSocket.open(DaemonManager::SOCKET_PATH) do |sock|
          sock.write("GET /localapi/v0/status HTTP/1.0\r\nHost: local\r\n\r\n")
          sock.flush
          response = sock.read
          response.split("\r\n\r\n", 2).last || ""
        end
      end

      def hosts
        Rails.application.config.hosts
      end
    end
  end
end
