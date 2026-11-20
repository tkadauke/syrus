# frozen_string_literal: true

module Syrus
  module Plugin
    class CapabilityProvider
      attr_reader :plugin_name, :family, :capability, :provider_name, :priority
      def initialize(plugin_name:, family:, capability:, provider_name:, priority:)
        @plugin_name, @family, @capability, @provider_name, @priority = plugin_name, family, capability, provider_name, priority
      end
      def invoke = yield Object.const_get(provider_name)
      def catalog_payload = { plugin: plugin_name, family:, capability:, provider: provider_name, priority: }
    end
  end
end
