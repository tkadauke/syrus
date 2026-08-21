require "ipaddr"

# Blocks server-side HTTP fetches from reaching private, loopback,
# link-local, or other non-routable network destinations. Used by code
# that downloads content from URLs embedded in untrusted GitHub issue/PR
# bodies (JobImageAttachmentIngestor, IngestIssueImagesJob) so a hostile
# issue/comment can't turn Syrus into an SSRF proxy against its own
# internal network (cloud metadata endpoints, cluster-internal services,
# etc).
#
# Deliberately string/literal-based, not DNS-resolving, mirroring
# SyrusBrowser::LoopbackGuard: resolving a hostname and checking the
# resolved address is vulnerable to DNS rebinding (a name that answers a
# public IP at check time and a private one a moment later, when Net::HTTP
# itself performs the connection). This blocks the common case — an
# attacker pasting a raw internal/loopback/link-local IP literal or a
# known-internal hostname directly into markdown — without adding a
# network dependency to the check itself.
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
    normalized = host.to_s.strip.downcase
    return false if normalized.blank?
    return false if BLOCKED_HOSTNAMES.include?(normalized)

    ip = parse_ip(normalized)
    return true unless ip

    blocked_ranges_for(ip).none? { |range| range.include?(ip) }
  end

  def self.parse_ip(normalized)
    IPAddr.new(normalized)
  rescue IPAddr::Error
    nil
  end
  private_class_method :parse_ip

  def self.blocked_ranges_for(ip)
    ip.ipv4? ? BLOCKED_IPV4_RANGES : BLOCKED_IPV6_RANGES
  end
  private_class_method :blocked_ranges_for
end
