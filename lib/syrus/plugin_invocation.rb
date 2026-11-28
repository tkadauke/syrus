# frozen_string_literal: true

require "timeout"

module Syrus
  # Uniform runtime boundary for calls from core into plugin providers.
  module PluginInvocation
    Declined = Data.define(:value)
    Failed = Data.define(:value, :exception_class, :message, :reason)

    DEFAULT_FAILURE_THRESHOLD = Integer(ENV.fetch("SYRUS_PLUGIN_CIRCUIT_FAILURE_THRESHOLD", 5))
    DEFAULT_FAILURE_WINDOW = Float(ENV.fetch("SYRUS_PLUGIN_CIRCUIT_WINDOW_SECONDS", 60))
    DEFAULT_COOLDOWN = Float(ENV.fetch("SYRUS_PLUGIN_CIRCUIT_COOLDOWN_SECONDS", 30))

    class << self
      attr_writer :runtime_health

      def call(extension_point:, provider:, operation:, timeout: nil, on_decline: nil,
        failure_threshold: DEFAULT_FAILURE_THRESHOLD, failure_window: DEFAULT_FAILURE_WINDOW,
        cooldown: DEFAULT_COOLDOWN, &block)
        plugin = Syrus::PluginRegistry.plugin_name_for(provider) || provider_name(provider)
        unless runtime_health.allow?(plugin: plugin, extension_point: extension_point, cooldown: cooldown)
          return Failed.new(value: decline_value(on_decline, :circuit_open), exception_class: nil, message: nil, reason: :circuit_open)
        end

        started_at = monotonic_now if timeout
        result = PerformanceLogging.plugin_call(extension_point: extension_point, provider: provider, operation: operation) do
          timeout ? Timeout.timeout(timeout, &block) : block.call
        end
        raise Timeout::Error, "execution expired" if timeout && monotonic_now - started_at >= timeout

        runtime_health.record_success(plugin: plugin, extension_point: extension_point)
        result
      rescue StandardError, NotImplementedError => error
        raise if test_framework_exception?(error)

        runtime_health.record_failure(
          plugin: plugin, extension_point: extension_point, operation: operation, exception: error,
          threshold: failure_threshold, window: failure_window, cooldown: cooldown
        )
        Failed.new(
          value: decline_value(on_decline, :failed), exception_class: error.class.name,
          message: error.message.to_s, reason: error.is_a?(Timeout::Error) ? :timeout : :failed
        )
      end

      def decline(value = nil) = Declined.new(value: value)
      def value(result) = result.is_a?(Declined) || result.is_a?(Failed) ? result.value : result
      def runtime_health = @runtime_health ||= PluginRuntimeHealth.new

      private

      def decline_value(on_decline, reason)
        if on_decline.respond_to?(:call)
          return on_decline.method(:call).arity.zero? ? on_decline.call : on_decline.call(reason)
        end

        on_decline
      end

      def provider_name(provider)
        target = provider.is_a?(Class) ? provider : provider.class
        target.name.presence || target.to_s
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def test_framework_exception?(error)
        [
          (RSpec::Expectations::ExpectationNotMetError if defined?(RSpec::Expectations::ExpectationNotMetError)),
          (Minitest::Assertion if defined?(Minitest::Assertion))
        ].compact.any? { |klass| error.is_a?(klass) }
      end
    end
  end
end
