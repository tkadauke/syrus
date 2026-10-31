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
        Configuration.coworker_proxy_url(provider_key)
      end

      def configured?
        dedicated_network? &&
          Configuration.coworker_dns.present? &&
          valid_proxy_url?
      end

      # This mirrors the hostname-aware proxy contract and gives conformance
      # tests one policy surface. The proxy remains the enforcement point.
      def allows_destination?(destination)
        host = normalized_host(destination)
        return false if host.blank? || blocked_address?(host)

        endpoint_hosts.include?(host)
      end

      def proxy_env
        {
          "HTTP_PROXY" => proxy_url,
          "HTTPS_PROXY" => proxy_url,
          "ALL_PROXY" => proxy_url,
          "NO_PROXY" => ""
        }
      end

      private

      def dedicated_network?
        network = Configuration.coworker_network.to_s.strip
        network.present? && !network.in?(%w[bridge default host none])
      end

      def valid_proxy_url?
        uri = URI.parse(proxy_url.to_s)
        uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      rescue URI::InvalidURIError
        false
      end

      def normalized_host(destination)
        value = destination.to_s.strip
        uri = URI.parse(value.include?("://") ? value : "https://#{value}")
        uri.host&.downcase&.delete_suffix(".")
      rescue URI::InvalidURIError
        nil
      end

      def blocked_address?(host)
        address = IPAddr.new(host)
        BLOCKED_NETWORKS.any? { |network| network.include?(address) }
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
