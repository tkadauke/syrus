require "ipaddr"
require "socket"

# Blocks server-side HTTP fetches from reaching private, loopback,
# link-local, or other non-routable network destinations. Used by code
# that downloads content from URLs embedded in untrusted GitHub issue/PR
# bodies (JobImageAttachmentIngestor, IngestIssueImagesJob) so a hostile
# issue/comment can't turn Syrus into an SSRF proxy against its own
# internal network (cloud metadata endpoints, cluster-internal services,
# etc).
#
# Canonical IP literals are checked directly. Hostnames and ambiguous
# numeric-looking forms are resolved before the fetch so libc-accepted
# aliases such as 127.1, decimal/hex/octal IPv4, and trailing-dot
# absolute names cannot bypass the private-range denylist.
class SsrfGuard
  INVALID_IP_LITERAL = Object.new.freeze
  IPV4_NUMERIC_COMPONENT = /(?:0x[0-9a-f]+|[0-9]+)/
  IPV4_NUMERIC_LITERAL = /\A#{IPV4_NUMERIC_COMPONENT}(?:\.#{IPV4_NUMERIC_COMPONENT}){0,3}\z/
  private_constant :INVALID_IP_LITERAL, :IPV4_NUMERIC_COMPONENT, :IPV4_NUMERIC_LITERAL

  BLOCKED_HOSTNAMES = %w[
    localhost
    metadata.google.internal
  ].freeze

  BLOCKED_IPV4_RANGES = [
    IPAddr.new("0.0.0.0/8"),
    IPAddr.new("10.0.0.0/8"),
    IPAddr.new("100.64.0.0/10"),
    IPAddr.new("127.0.0.0/8"),
    IPAddr.new("169.254.0.0/16"),
    IPAddr.new("172.16.0.0/12"),
    IPAddr.new("192.0.0.0/24"),
    IPAddr.new("192.0.2.0/24"),
    IPAddr.new("192.168.0.0/16"),
    IPAddr.new("198.18.0.0/15"),
    IPAddr.new("198.51.100.0/24"),
    IPAddr.new("203.0.113.0/24"),
    IPAddr.new("224.0.0.0/4"),
    IPAddr.new("240.0.0.0/4")
  ].freeze

  BLOCKED_IPV6_RANGES = [
    IPAddr.new("::1/128"),
    IPAddr.new("::/128"),
    IPAddr.new("::ffff:0:0/96"),
    IPAddr.new("64:ff9b::/96"),
    IPAddr.new("fc00::/7"),
    IPAddr.new("fe80::/10"),
    IPAddr.new("ff00::/8")
  ].freeze

  def self.safe_host?(host)
    normalized = normalize_host(host)
    return false if normalized.blank?
    return false if BLOCKED_HOSTNAMES.include?(normalized)

    ip = parse_ip(normalized)
    return false if ip == INVALID_IP_LITERAL
    return allowed_ip?(ip) if ip

    resolved_ips = resolved_ips_for(normalized)
    return false if resolved_ips.empty?

    resolved_ips.all? { |resolved_ip| allowed_ip?(resolved_ip) }
  end

  def self.normalize_host(host)
    normalized = host.to_s.strip.downcase
    normalized = normalized.chomp(".") if normalized.length > 1
    normalized
  end
  private_class_method :normalize_host

  def self.parse_ip(normalized)
    IPAddr.new(normalized)
  rescue IPAddr::Error
    parse_noncanonical_ipv4(normalized)
  end
  private_class_method :parse_ip

  def self.parse_noncanonical_ipv4(normalized)
    return nil unless IPV4_NUMERIC_LITERAL.match?(normalized)

    parts = normalized.split(".").map { |part| parse_ipv4_numeric_component(part) }
    return INVALID_IP_LITERAL if parts.any?(&:nil?)

    address = ipv4_address_from_parts(parts)
    return INVALID_IP_LITERAL unless address

    IPAddr.new(
      [
        (address >> 24) & 0xff,
        (address >> 16) & 0xff,
        (address >> 8) & 0xff,
        address & 0xff
      ].join(".")
    )
  end
  private_class_method :parse_noncanonical_ipv4

  def self.parse_ipv4_numeric_component(part)
    if part.start_with?("0x")
      Integer(part[2..], 16)
    elsif part.length > 1 && part.start_with?("0")
      Integer(part, 8)
    else
      Integer(part, 10)
    end
  rescue ArgumentError
    nil
  end
  private_class_method :parse_ipv4_numeric_component

  def self.ipv4_address_from_parts(parts)
    case parts.length
    when 1
      value = parts[0]
      return nil unless value <= 0xffffffff

      value
    when 2
      first, rest = parts
      return nil unless first <= 0xff && rest <= 0xffffff

      (first << 24) | rest
    when 3
      first, second, rest = parts
      return nil unless first <= 0xff && second <= 0xff && rest <= 0xffff

      (first << 24) | (second << 16) | rest
    when 4
      return nil unless parts.all? { |part| part <= 0xff }

      parts.reduce(0) { |address, part| (address << 8) | part }
    end
  end
  private_class_method :ipv4_address_from_parts

  def self.resolved_ips_for(normalized)
    Addrinfo
      .getaddrinfo(normalized, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
      .filter_map { |addrinfo| parse_ip(addrinfo.ip_address) }
      .uniq
  rescue SocketError, SystemCallError
    []
  end
  private_class_method :resolved_ips_for

  def self.allowed_ip?(ip)
    blocked_ranges_for(ip).none? { |range| range.include?(ip) }
  end
  private_class_method :allowed_ip?

  def self.blocked_ranges_for(ip)
    ip.ipv4? ? BLOCKED_IPV4_RANGES : BLOCKED_IPV6_RANGES
  end
  private_class_method :blocked_ranges_for
end
