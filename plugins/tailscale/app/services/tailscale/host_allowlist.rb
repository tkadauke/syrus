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
        data = RemoteStatus.call
        return [] unless data

        dns_name = data["hostname"]
        ips = data["tailscale_ips"] || []

        [dns_name, *ips].compact.reject(&:blank?)
      end

      def hosts
        Rails.application.config.hosts
      end
    end
  end
end
