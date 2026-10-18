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
      validate_key_blob!(decoded)
      @known_host = "#{entry_host} #{@key_type} #{@key_data}"
      @fingerprint = "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(decoded)).delete_suffix('=')}"
    rescue ArgumentError
      raise SshExec::InvalidTarget, "known-host entry contains an invalid public key"
    end

    def as_json(*) = { host: host, port: port, key_type: key_type, fingerprint: fingerprint, known_host: known_host }

    private

    def validate_key_blob!(blob)
      reader = WireReader.new(blob)
      encoded_type = reader.read_string
      raise SshExec::InvalidTarget, "known-host key type does not match its public key" unless encoded_type == key_type

      BlobValidator.for(key_type).validate!(reader)
      raise SshExec::InvalidTarget, "known-host entry contains trailing public-key data" unless reader.eof?
    rescue WireReader::Malformed
      raise SshExec::InvalidTarget, "known-host entry contains a malformed public key"
    end

    class WireReader
      class Malformed < StandardError; end

      def initialize(value) = @value = value

      def read_string
        raise Malformed if @value.bytesize < 4
        length = @value.unpack1("N")
        raise Malformed if length > @value.bytesize - 4
        result = @value.byteslice(4, length)
        @value = @value.byteslice(4 + length..) || +""
        result
      end

      def eof? = @value.empty?
    end

    class BlobValidator
      REGISTRY = {
        "ssh-ed25519" => -> { Ed25519.new },
        "ssh-rsa" => -> { Rsa.new },
        "ecdsa-sha2-nistp256" => -> { Ecdsa.new("nistp256", 65) },
        "ecdsa-sha2-nistp384" => -> { Ecdsa.new("nistp384", 97) },
        "ecdsa-sha2-nistp521" => -> { Ecdsa.new("nistp521", 133) }
      }.freeze

      def self.for(key_type) = REGISTRY.fetch(key_type).call

      class Ed25519
        def validate!(reader)
          raise SshExec::InvalidTarget, "known-host entry contains an invalid Ed25519 key" unless reader.read_string.bytesize == 32
        end
      end

      class Rsa
        def validate!(reader)
          exponent = reader.read_string
          modulus = reader.read_string
          valid = valid_positive_mpint?(exponent) && valid_positive_mpint?(modulus) && modulus.bytesize >= 128
          raise SshExec::InvalidTarget, "known-host entry contains an invalid RSA key" unless valid
        end

        private

        def valid_positive_mpint?(value)
          return false if value.empty? || value.getbyte(0) & 0x80 != 0
          return false if value.bytesize > 1 && value.getbyte(0).zero? && value.getbyte(1) & 0x80 == 0
          value.bytes.any?(&:positive?)
        end
      end

      class Ecdsa
        def initialize(curve, point_bytes)
          @curve = curve
          @point_bytes = point_bytes
        end

        def validate!(reader)
          raise SshExec::InvalidTarget, "known-host ECDSA curve does not match its key type" unless reader.read_string == @curve
          point = reader.read_string
          raise SshExec::InvalidTarget, "known-host entry contains an invalid ECDSA key" unless point.bytesize == @point_bytes && point.getbyte(0) == 4
        end
      end
    end

    def expected_host_token = port == 22 ? host : "[#{host}]:#{port}"
  end
end
