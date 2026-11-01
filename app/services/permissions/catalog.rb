module Permissions
  class Catalog
    class UnknownCapability < ArgumentError; end

    def self.descriptors
      McpToolRegistry.entries.map(&:descriptor).uniq { |descriptor| [ descriptor.capability, descriptor.operation ] }
    end

    def self.find!(capability:, operation: nil)
      matches = descriptors.select { |descriptor| descriptor.capability == capability.to_s }
      matches.select! { |descriptor| descriptor.operation == operation.to_s } if operation.present?
      raise UnknownCapability, "unknown permission capability or operation" unless matches.one?

      matches.first
    end

    def self.as_json(descriptor)
      descriptor.to_h.except(:classifier, :fingerprint_normalizer, :redactor).merge(
        resource_scope: descriptor.resource_scope.to_h
      )
    end
  end
end
