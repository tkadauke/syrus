require "digest"
require "json"

module LocalBackups
  class Manifest
    VERSION = 1
    FILE_NAME = "manifest.json"
    REQUIRED = %w[manifest_version backup_id installation_id completed_at validated_at database storage encryption_fingerprints artifact validation].freeze
    Error = Class.new(StandardError)
    UnknownVersion = Class.new(Error)
    Invalid = Class.new(Error)

    attr_reader :data

    def self.read(path)
      path = Pathname(path)
      raise Invalid, "manifest must be a regular file" unless path.file? && !path.symlink?

      parsed = JSON.parse(path.binread)
      new(parsed).tap(&:validate!)
    rescue JSON::ParserError => e
      raise Invalid, "invalid manifest JSON: #{e.message}"
    end

    def initialize(data)
      @data = data.deep_stringify_keys
    end

    def write_once(path)
      validate!
      path = Pathname(path)
      path.dirname.mkpath
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(data) << "\n")
        file.flush
        file.fsync
      end
      path
    rescue Errno::EEXIST
      raise Invalid, "manifest already exists"
    end

    def validate!
      version = Integer(data["manifest_version"], exception: false)
      raise UnknownVersion, "unsupported manifest version #{data['manifest_version'].inspect}" unless version == VERSION

      missing = REQUIRED.reject { |key| data.key?(key) }
      raise Invalid, "missing fields: #{missing.join(', ')}" if missing.any?
      raise Invalid, "database, storage, artifact, validation, and encryption_fingerprints must be objects" unless %w[database storage artifact validation encryption_fingerprints].all? { |key| data[key].is_a?(Hash) }
      raise Invalid, "backup_id must be a UUID" unless data["backup_id"].to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
      raise Invalid, "artifact checksum must use sha256" unless data.dig("artifact", "checksum_algorithm") == "sha256"
      raise Invalid, "artifact checksum is invalid" unless data.dig("artifact", "checksum").to_s.match?(/\A[0-9a-f]{64}\z/i)
      unless data.fetch("encryption_fingerprints").values.all? { |value| value.to_s.match?(/\Asha256:[0-9a-f]{64}\z/i) }
        raise Invalid, "encryption fingerprints must contain only non-secret sha256 digests"
      end
      raise Invalid, "manifest is not sealed and valid" unless data.dig("validation", "result") == "valid"
      self
    end

    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate(canonical(data)))
    end

    private

    def canonical(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end
  end
end
