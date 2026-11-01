require "ipaddr"
require "uri"

module ContainerExecution
  module EgressPolicy
    class Base
      BLOCKED_NETWORKS = %w[
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
        172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4
        ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
      ].map { |cidr| IPAddr.new(cidr) }.freeze

      def self.for(provider)
        policies.find { |policy| policy.provider_key == provider.to_s }&.new
      end

      def self.policies = [ Codex, Claude, Muse, Agy ]

      def profile = provider_key
      def endpoint_hosts = self.class::ENDPOINT_HOSTS

      def proxy_url
        Configuration.chat_agent_proxy_url(provider_key)
      end

      def configured?
        dedicated_network? &&
          Configuration.chat_agent_dns.present? &&
          valid_proxy_url?
      end

      # This mirrors the hostname-aware proxy contract and gives conformance
      # tests one policy surface. The proxy remains the enforcement point.
      def allows_destination?(destination)
        host, port = normalized_destination(destination)
        return deny_destination(host, port) if host.blank? || blocked_address?(host)

        endpoint_hosts.include?(host) || deny_destination(host, port)
      end

      def proxy_env
        uppercase = {
          "HTTP_PROXY" => proxy_url,
          "HTTPS_PROXY" => proxy_url,
          "ALL_PROXY" => proxy_url,
          "NO_PROXY" => ""
        }
        uppercase.merge(uppercase.transform_keys(&:downcase))
      end

      private

      def dedicated_network?
        network = Configuration.chat_agent_network.to_s.strip
        network.present? && !network.in?(%w[bridge default host none])
      end

      def valid_proxy_url?
        uri = URI.parse(proxy_url.to_s)
        uri.is_a?(URI::HTTP) && uri.hostname.present? && !blocked_address?(uri.hostname) &&
          uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      rescue URI::Error
        false
      end

      def normalized_destination(destination)
        value = destination.to_s.strip
        uri = URI.parse(value.include?("://") ? value : "https://#{value}")
        [ uri.hostname&.downcase&.delete_suffix("."), uri.port ]
      rescue URI::Error
        [ nil, nil ]
      end

      def deny_destination(host, port)
        Rails.logger.info(
          event: "coworker_egress_denied",
          profile: profile,
          destination_host: host.presence || "invalid",
          destination_port: port
        )
        false
      end

      def blocked_address?(host)
        address = IPAddr.new(host)
        address = address.native if address.ipv4_mapped?
        BLOCKED_NETWORKS.any? { |network| network.include?(address) }
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
