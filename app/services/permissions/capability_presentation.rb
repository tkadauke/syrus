module Permissions
  # Human-facing metadata carried by every capability descriptor. Identifiers
  # remain the stable audit/rule contract; this metadata is the UI contract.
  class CapabilityPresentation
    attr_reader :capability_name, :operation_name

    def self.for(capability:, operation:)
      new(
        capability_name: humanize(identifier_part(capability)),
        operation_name: humanize(identifier_part(operation).split("/").last)
      )
    end

    def self.identifier_part(identifier) = identifier.to_s.delete_suffix(identifier.to_s[/@v\d+\z/].to_s)

    def self.humanize(value)
      value.to_s.tr("._-", " ").split.map { |word| word.casecmp?("syrus") ? "Syrus" : word.capitalize }.join(" ")
    end

    def initialize(capability_name:, operation_name:)
      @capability_name = capability_name.to_s.strip
      @operation_name = operation_name.to_s.strip
      raise ArgumentError, "capability presentation name is required" if @capability_name.blank?
      raise ArgumentError, "operation presentation name is required" if @operation_name.blank?

      freeze
    end

    def to_h = { capability_name:, operation_name: }
  end
end
