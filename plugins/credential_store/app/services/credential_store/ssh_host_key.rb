require "base64"
require "digest"
require "ipaddr"

module CredentialStore
  class SshHostKey
    KEY_TYPES = %w[ssh-ed25519 ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 ssh-rsa].freeze
    HOSTNAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9.-]*\z/.freeze

    attr_reader :host, :port, :key_type, :key_data, :known_host, :fingerprint

    def self.parse!(line:, host:, port:) = new(line: line, host: host, port: port)

    def self.valid_host?(host)
      return false if host.blank? || host.start_with?("-") || host.bytesize > 253
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError
      host.match?(HOSTNAME_PATTERN) && host.split(".").all? { |label| label.present? && label.bytesize <= 63 && !label.start_with?("-") && !label.end_with?("-") }
    end

    def self.normalize_port!(value)
      port = Integer(value.presence || 22, exception: false)
      raise SshExec::InvalidTarget, "port must be between 1 and 65535" unless port&.between?(1, 65_535)
      port
    end

    def initialize(line:, host:, port:)
      @host = host.to_s.strip
      raise SshExec::InvalidTarget, "host must be a hostname or IP address" unless self.class.valid_host?(@host)
      @port = self.class.normalize_port!(port)
      fields = line.to_s.strip.split(/\s+/)
      raise SshExec::InvalidTarget, "known-host entry must contain a host, key type, and public key" unless fields.length == 3
      entry_host, @key_type, @key_data = fields
      raise SshExec::InvalidTarget, "known-host entry does not match the requested host and port" unless entry_host == expected_host_token
      raise SshExec::InvalidTarget, "known-host entry uses an unsupported key type" unless KEY_TYPES.include?(@key_type)
      decoded = Base64.strict_decode64(@key_data)
      raise SshExec::InvalidTarget, "known-host entry contains an invalid public key" if decoded.empty?
      @known_host = "#{entry_host} #{@key_type} #{@key_data}"
      @fingerprint = "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(decoded)).delete_suffix('=')}"
    rescue ArgumentError
      raise SshExec::InvalidTarget, "known-host entry contains an invalid public key"
    end

    def as_json(*) = { host: host, port: port, key_type: key_type, fingerprint: fingerprint, known_host: known_host }

    private

    def expected_host_token = port == 22 ? host : "[#{host}]:#{port}"
  end
end
