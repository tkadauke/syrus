require "uri"

module SyrusBrowser
  # Hard SSRF/exfiltration guard for the browser MCP tool set: an LLM driving
  # a real Chromium instance must only ever be able to reach the worker's own
  # in-step preview (started via the start_preview MCP tool), never an
  # arbitrary URL on the network or public internet. Enforced here, in the
  # tool handler (SyrusBrowser::McpToolSet#handle_navigate) — not just in the
  # agent prompt — so a malicious or confused navigate call is rejected
  # regardless of what the agent asks for.
  #
  # Deliberately string-based, not DNS-based: resolving a hostname and
  # checking whether the resolved address is loopback is vulnerable to DNS
  # rebinding (a name that answers 127.0.0.1 at check time and something
  # else a moment later, when Chromium itself performs the connection).
  # Only a small, fixed set of literal loopback spellings is allowed; any
  # other hostname is rejected outright, resolvable-to-loopback or not.
  module LoopbackGuard
    ALLOWED_SCHEMES = %w[http https].freeze

    def self.allowed?(url)
      uri = parse(url)
      return false unless uri
      return false unless ALLOWED_SCHEMES.include?(uri.scheme.to_s.downcase)
      return false if uri.hostname.blank?

      loopback_host?(uri.hostname)
    end

    def self.parse(url)
      URI.parse(url.to_s)
    rescue URI::InvalidURIError
      nil
    end
    private_class_method :parse

    def self.loopback_host?(host)
      normalized = host.to_s.downcase
      return true if normalized == "localhost"
      return true if normalized == "::1"

      # Any literal 127.x.x.x address is loopback per RFC 5735/6890, not
      # just 127.0.0.1.
      normalized.match?(/\A127(?:\.\d{1,3}){3}\z/)
    end
    private_class_method :loopback_host?
  end
end
