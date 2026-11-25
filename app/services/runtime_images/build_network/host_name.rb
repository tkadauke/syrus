require "ipaddr"

module RuntimeImages
  module BuildNetwork
    # Canonical form for a destination host. Builds may only name DNS hosts:
    # anything that parses as an address in any notation (dotted, decimal, hex,
    # octal, bracketed IPv6) is a literal-IP bypass attempt.
    module HostName
      LABEL = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
      NUMERIC_LITERAL = /\A(0x[0-9a-f]+|\d+)(\.(0x[0-9a-f]+|\d+))*\z/i

      def self.literal?(host)
        value = host.to_s.strip
        return true if value.start_with?("[") || value.include?(":")
        return true if value.match?(NUMERIC_LITERAL)

        IPAddr.new(value)
        true
      rescue IPAddr::Error
        false
      end

      # Lowercases, strips one trailing dot, and requires a plain ASCII DNS
      # name with at least two labels. Returns nil for anything else.
      def self.normalize(host)
        value = host.to_s.strip.downcase.chomp(".")
        return nil if value.empty? || value.length > 253 || !value.ascii_only?
        return nil if literal?(value)

        labels = value.split(".", -1)
        return nil if labels.size < 2 || !labels.all? { |label| label.match?(LABEL) }

        value
      end
    end
  end
end
