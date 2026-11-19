require "digest"
require "json"

module LocalBackups
  class Manifest
    FILE_NAME = "manifest.json"
    VERSION = "1.0"
    REQUIRED = %w[manifest_version backup_id completed_at artifact checksum].freeze

    class Invalid < StandardError; end
    class UnsupportedVersion < Invalid; end

    def self.read(path)
      payload = JSON.parse(Pathname.new(path).binread)
      missing = REQUIRED - payload.keys
      raise Invalid, "manifest is missing #{missing.join(', ')}" if missing.any?
      raise UnsupportedVersion, "unsupported manifest version #{payload['manifest_version']}" unless compatible?(payload["manifest_version"])

      new(payload)
    rescue JSON::ParserError => e
      raise Invalid, e.message
    end

    def self.write(directory, attributes)
      directory = Pathname.new(directory)
      destination = directory.join(FILE_NAME)
      payload = attributes.deep_stringify_keys.merge("manifest_version" => VERSION)
      missing = REQUIRED - payload.keys
      raise Invalid, "manifest is missing #{missing.join(', ')}" if missing.any?

      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(payload.sort.to_h))
        file.write("\n")
        file.flush
        file.fsync
      end
      destination
    end

    def self.compatible?(version)
      major, minor = version.to_s.split(".", 2).map { |part| Integer(part, 10) }
      major == 1 && minor >= 0
    rescue ArgumentError, TypeError
      false
    end

    attr_reader :attributes

    def initialize(attributes)
      @attributes = attributes.deep_stringify_keys.freeze
    end

    def checksum
      attributes.fetch("checksum")
    end
  end
end
