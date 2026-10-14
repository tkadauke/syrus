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
    nil
  end
  private_class_method :parse_ip

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
