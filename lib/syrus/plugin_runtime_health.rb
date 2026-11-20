# frozen_string_literal: true

module Syrus
  # Process-local runtime failure and circuit state for plugin providers.
  class PluginRuntimeHealth
    MAX_FAILURES_PER_PLUGIN = 100

    Failure = PluginHealth::Finding
    Circuit = Data.define(:plugin, :extension_point, :state, :failure_count, :opened_at, :retry_at)

    def initialize(clock: -> { Time.current }, max_failures_per_plugin: MAX_FAILURES_PER_PLUGIN)
      @clock = clock
      @max_failures_per_plugin = max_failures_per_plugin
      @mutex = Mutex.new
      @failures = {}
      @circuits = {}
    end

    def allow?(plugin:, extension_point:, cooldown:)
      key = circuit_key(plugin, extension_point)
      @mutex.synchronize do
        circuit = @circuits[key]
        return true unless circuit
        return true if circuit[:state] == :closed
        return false if circuit[:state] == :half_open
        return false if now < circuit[:opened_at] + circuit.fetch(:cooldown, cooldown)

        circuit[:state] = :half_open
        true
      end
    end

    def record_success(plugin:, extension_point:)
      @mutex.synchronize { @circuits.delete(circuit_key(plugin, extension_point)) }
    end

    def record_failure(plugin:, extension_point:, operation:, exception:, threshold:, window:, cooldown:, circuit: true,
      family: nil, provider: nil)
      timestamp = now
      @mutex.synchronize do
        failure_key = [ plugin.to_s, extension_point.to_s, operation.to_s, exception.class.name, exception.message.to_s ]
        previous = @failures[failure_key]
        @failures[failure_key] = Failure.runtime(
          plugin:, family:, provider:, extension_point:, operation:, exception:,
          count: previous.to_h.fetch(:count, 0) + 1, last_at: timestamp
        ).to_h
        prune_failures(plugin.to_s)

        next unless circuit

        key = circuit_key(plugin, extension_point)
        circuit = (@circuits[key] ||= { state: :closed, failures: [] })
        circuit[:failures] = circuit[:failures].select { |failed_at| failed_at >= timestamp - window }
        circuit[:failures] << timestamp
        if circuit[:state] == :half_open || circuit[:failures].size >= threshold
          circuit[:state] = :open
          circuit[:opened_at] = timestamp
          circuit[:cooldown] = cooldown
        end
      end
    end

    def failures(plugin: nil)
      @mutex.synchronize do
        @failures.values
          .select { |failure| plugin.nil? || failure[:plugin] == plugin.to_s }
          .map { |failure| Failure.new(**failure) }
      end
    end

    def circuits(plugin: nil)
      timestamp = now
      @mutex.synchronize do
        @circuits.filter_map do |(plugin_name, extension_point), circuit|
          next if circuit[:state] == :closed
          next if plugin && plugin_name != plugin.to_s

          retry_at = circuit[:opened_at] && circuit[:opened_at] + circuit.fetch(:cooldown)
          Circuit.new(
            plugin: plugin_name, extension_point: extension_point, state: circuit[:state],
            failure_count: circuit[:failures].count { |failed_at| failed_at <= timestamp },
            opened_at: circuit[:opened_at], retry_at: retry_at
          )
        end
      end
    end

    def reset!(clock: nil)
      @mutex.synchronize do
        @clock = clock if clock
        @failures.clear
        @circuits.clear
      end
    end

    private

    def now = @clock.call
    def circuit_key(plugin, extension_point) = [ plugin.to_s, extension_point.to_s ]

    def prune_failures(plugin)
      plugin_failures = @failures.select { |key, _failure| key.first == plugin }
      overflow = plugin_failures.size - @max_failures_per_plugin
      return unless overflow.positive?

      plugin_failures
        .min_by(overflow) { |_key, failure| failure.fetch(:last_at) }
        .each { |key, _failure| @failures.delete(key) }
    end
  end
end
