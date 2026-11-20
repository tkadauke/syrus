# frozen_string_literal: true

module Syrus
  module Plugin
    module Composition
      class MissingKey < KeyError; end
      module_function
      def collect(providers, &call) = providers.flat_map { |provider| Array(provider.invoke(&call)) }
      def broadcast(providers, &call) = providers.each { |provider| provider.invoke(&call) }.then { nil }
      def first_claim(providers, &call)
        providers.each do |provider|
          value = provider.invoke(&call)
          return value unless value.nil?
        rescue StandardError
          next
        end
        nil
      end
      def keyed(providers, key, &call)
        provider = providers.find { |candidate| candidate.invoke { |implementation| implementation.key.to_s == key.to_s } }
        raise MissingKey, "No capability provider for key #{key.inspect}" unless provider
        provider.invoke(&call)
      end
    end
  end
end
