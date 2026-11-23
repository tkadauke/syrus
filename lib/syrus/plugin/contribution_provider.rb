# frozen_string_literal: true

module Syrus
  module Plugin
    # Shared building blocks for facets whose capabilities return the established
    # duck-typed behavior modules (or arrays of them) while their multi-operation
    # interfaces are decomposed. Provider constants stay lazy, so manifest and
    # catalog reads never resolve plugin application code.
    module ContributionProvider
      ReturnShape = Data.define(:description, :validator) do
        def valid?(value) = validator.call(value)
      end
      OPTIONAL_PROVIDER = ReturnShape.new(
        description: "Module, Array<Module>, or nil",
        validator: ->(value) { value.nil? || value.is_a?(Module) || (value.is_a?(Array) && value.all? { |item| item.is_a?(Module) }) }
      )

      # Expands a family declaration into legacy provider modules for callers
      # that still read the legacy registry through the bridge.
      class LegacyAdapter
        def initialize(capability, context_class)
          @capability = capability
          @context_class = context_class
        end

        def dispatch(provider, _context) = provider

        def legacy_providers(provider)
          Array(provider.public_send(@capability, @context_class.new)).compact
        end
      end

      # +interfaces+ maps a capability to a lambda returning the interface module
      # every contribution for it must include, exactly as the legacy `provides`
      # DSL did for its extension point.
      def self.build(key:, display_name:, interfaces: {}, **contributions)
        implementations = contributions.values.flatten.compact.freeze
        Class.new do
          define_singleton_method(:key) { key.to_s }
          define_singleton_method(:display_name) { display_name.to_s }
          define_singleton_method(:owns_implementation?) do |candidate|
            candidate_class = candidate.is_a?(Module) ? candidate : candidate.class
            implementations.any? { |item| item.is_a?(String) ? item == candidate_class.name : item.equal?(candidate_class) }
          end
          contributions.each do |capability, names|
            define_singleton_method(capability) do |context|
              next nil unless context.enabled
              resolved = Array(names).map { |name| name.is_a?(String) ? Object.const_get(name) : name }
              interface = interfaces[capability]&.call
              resolved.each { |item| item.include(interface) unless item.include?(interface) } if interface
              names.is_a?(Array) ? resolved : resolved.first
            end
          end
        end
      end
    end
  end
end
