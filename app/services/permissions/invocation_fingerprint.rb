require "digest"

module Permissions
  class InvocationFingerprint
    def self.call(descriptor:, arguments:)
      normalized = descriptor.normalize_fingerprint(arguments).to_h
      Digest::SHA256.hexdigest(JSON.generate(canonical(identity(descriptor, normalized))))
    end

    # A prefix-matchable projection of an argument is an input to *matching*,
    # not part of what makes one invocation distinct from another: the exact
    # identity is already carried by the argument it was projected from. Hashing
    # it would make a fingerprint depend on how a rule might be phrased, and
    # would change every fingerprint already issued for a descriptor that later
    # gains a prefix field.
    def self.identity(descriptor, normalized)
      prefix_fields = descriptor.constraint_fields.select { |_name, type| type == :string_prefix }.keys
      return normalized if prefix_fields.empty?

      normalized.reject { |key, _value| prefix_fields.include?(key.to_s) }
    end
    private_class_method :identity

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
