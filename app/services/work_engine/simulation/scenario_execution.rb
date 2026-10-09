# frozen_string_literal: true

module WorkEngine
  module Simulation
    class ScenarioExecution
      def self.call(...) = new(...).call
      def self.wrap(...) = new.wrap(...)

      def initialize(path: nil, max_ticks: nil)
        @path = path
        @max_ticks = max_ticks
      end

      def call
        wrap do
          WorkEngine::Simulation::ScenarioRunner.call(path: path, max_ticks: max_ticks)
        end
      end

      def wrap
        result = nil
        Syrus::PluginRegistry.with_plugin_record_cache_ttl(5.minutes) do
          AppSetting.with_current_cache do
            # The simulator must exercise commit callbacks, because dependent
            # starts, epic rollups, and domain events are committed-work
            # propagation. The wrapper is deliberately non-joinable: inner
            # saves open their own savepoints and run after_commit callbacks
            # when those savepoints commit, while this outer rollback still
            # discards all fixture rows after the scenario or spec finishes.
            ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
              result = yield
              raise ActiveRecord::Rollback
            end
          end
        end
        result
      end

      private

      attr_reader :path, :max_ticks
    end
  end
end
