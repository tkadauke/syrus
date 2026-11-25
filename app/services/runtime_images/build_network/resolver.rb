require "socket"
require "timeout"

module RuntimeImages
  module BuildNetwork
    # Resolves an allowlisted host exactly once per connection and returns only
    # addresses that are safe to dial. The proxy connects to the returned
    # address itself, never to the name again, so the name cannot be re-bound
    # to a different address between the check and the connection (DNS
    # rebinding). One forbidden answer among several fails the whole lookup,
    # so a mixed public/private record set cannot be used to probe the network.
    class Resolver
      class Blocked < Error
        attr_reader :reason

        def initialize(reason, message = reason)
          @reason = reason
          super(message)
        end
      end

      LOOKUP_TIMEOUT = 5

      def initialize(lookup: nil)
        @lookup = lookup || ->(host) { Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address) }
      end

      def resolve(host, allow_private: false)
        addresses = Timeout.timeout(LOOKUP_TIMEOUT) { Array(@lookup.call(host)) }.map { |value| IPAddr.new(value.to_s) }.uniq
        raise Blocked.new("dns_unresolved", "#{host} did not resolve") if addresses.empty?

        addresses.each do |address|
          next unless AddressGuard.blocked?(address, allow_private: allow_private)

          raise Blocked.new("destination_address_forbidden", "#{host} resolves to a forbidden #{AddressGuard.classify(address)} address")
        end
        addresses.map(&:to_s)
      rescue Timeout::Error, SocketError, IPAddr::Error => e
        raise Blocked.new("dns_unresolved", "#{host} could not be resolved: #{e.class}")
      end
    end
  end
end
