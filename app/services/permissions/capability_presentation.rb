module Permissions
  # Human-facing metadata carried by every capability descriptor. Identifiers
  # remain the stable audit/rule contract; this metadata is the UI contract.
  class CapabilityPresentation
    attr_reader :capability_name, :capability_description, :operation_name, :operation_description

    def self.for(capability:, operation:)
      new(
        capability_name: humanize(identifier_part(capability)),
        capability_description: "Permits access to #{humanize(identifier_part(capability))} capabilities.",
        operation_name: humanize(identifier_part(operation).split("/").last),
        operation_description: "Permits an agent to #{humanize(identifier_part(operation).split("/").last).downcase}."
      )
    end

    def self.identifier_part(identifier) = identifier.to_s.delete_suffix(identifier.to_s[/@v\d+\z/].to_s)

    def self.humanize(value)
      value.to_s.tr("._-", " ").split.map { |word| word.casecmp?("syrus") ? "Syrus" : word.capitalize }.join(" ")
    end

    def initialize(capability_name:, capability_description:, operation_name:, operation_description:)
      @capability_name = capability_name.to_s.strip
      @capability_description = capability_description.to_s.strip
      @operation_name = operation_name.to_s.strip
      @operation_description = operation_description.to_s.strip
      raise ArgumentError, "capability presentation name is required" if @capability_name.blank?
      raise ArgumentError, "capability presentation description is required" if @capability_description.blank?
      raise ArgumentError, "operation presentation name is required" if @operation_name.blank?
      raise ArgumentError, "operation presentation description is required" if @operation_description.blank?

      freeze
    end

    def to_h = { capability_name:, capability_description:, operation_name:, operation_description: }
  end
end
