require "digest"

module Permissions
  class InvocationFingerprint
    def self.call(descriptor:, arguments:)
      normalized = descriptor.normalize_fingerprint(arguments)
      Digest::SHA256.hexdigest(JSON.generate(canonical(normalized)))
    end

    def self.canonical(value)
      case value
      when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
      when Array then value.map { |item| canonical(item) }
      when Symbol then value.to_s
      else value
      end
    end
    private_class_method :canonical
  end
end
