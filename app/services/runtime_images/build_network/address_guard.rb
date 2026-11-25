require "ipaddr"

module RuntimeImages
  module BuildNetwork
    # Classifies a resolved address. Some classes are never reachable by a
    # build, whatever an administrator declared; ordinary private space is
    # reachable only through a declared internal mirror.
    module AddressGuard
      NEVER = {
        metadata: %w[169.254.169.254/32 100.100.100.200/32 192.0.0.192/32 fd00:ec2::254/128 fd00:ec2::/64],
        loopback: %w[127.0.0.0/8 ::1/128],
        link_local: %w[169.254.0.0/16 fe80::/10],
        unspecified: %w[0.0.0.0/8 ::/128],
        multicast: %w[224.0.0.0/4 ff00::/8],
        reserved: %w[240.0.0.0/4 192.0.0.0/24 192.0.2.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
                     2001::/32 2001:db8::/32 2002::/16 100::/64]
      }.transform_values { |ranges| ranges.map { |range| IPAddr.new(range) }.freeze }.freeze

      PRIVATE = {
        private: %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7],
        shared_address_space: %w[100.64.0.0/10]
      }.transform_values { |ranges| ranges.map { |range| IPAddr.new(range) }.freeze }.freeze

      NAT64 = IPAddr.new("64:ff9b::/96")

      # Returns :public, a NEVER key, or a PRIVATE key.
      def self.classify(address)
        ip = normalize(address)
        NEVER.each { |label, ranges| return label if ranges.any? { |range| range.include?(ip) } }
        PRIVATE.each { |label, ranges| return label if ranges.any? { |range| range.include?(ip) } }
        :public
      end

      def self.blocked?(address, allow_private: false)
        label = classify(address)
        return false if label == :public
        return false if allow_private && PRIVATE.key?(label)

        true
      end

      # IPv4-mapped (::ffff:a.b.c.d) and NAT64 addresses are judged by the IPv4
      # address they embed, so they cannot be used to dress up a private target.
      def self.normalize(address)
        ip = address.is_a?(IPAddr) ? address : IPAddr.new(address.to_s)
        ip = ip.native
        if ip.ipv6? && NAT64.include?(ip)
          ip = IPAddr.new(ip.to_i & 0xffffffff, Socket::AF_INET)
        end
        ip
      end
    end
  end
end
