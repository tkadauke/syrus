module Syrus
  # The instrumentation facade. One API for core and plugins; nothing at a call
  # site knows or cares who is consuming the numbers.
  #
  #   Syrus::Metrics.declare do
  #     counter :runs_total, tags: %i[state trigger_kind], comment: "Runs by terminal state"
  #   end
  #
  #   Syrus::Metrics.counter(:runs_total).increment(tags: { state: "succeeded", trigger_kind: "initial" })
  #
  # Two guarantees the call sites depend on, because this runs in hot paths and
  # inside `ensure` blocks:
  #
  #   * it never raises in production -- a metrics bug must not fail a Run
  #   * it never blocks -- no IO, no DB, no network on the instrumentation path
  #
  # Counters here are **cumulative and monotonic**. They are never reset, and
  # rates are computed at read time by whoever asks (`rate()` in PromQL). That
  # is what removes the entire class of "did we reset before or after the scrape
  # read it?" bugs that the delta/push model has to solve. See
  # docs/plans/complete/prometheus-dashboard.md.
  module Metrics
    class Error < StandardError; end
    class UnknownMetric < Error; end

    class << self
      def registry
        @registry ||= Registry.new
      end

      # Core declarations. Owner defaults to :core; the plugin manifest DSL
      # calls `declare_plugin` instead so the registry can apply the namespace
      # prefix itself.
      def declare(owner: :core, &block)
        registry.declare(owner: owner, &block)
      end

      # Declares on behalf of a plugin, returning the fully-qualified names so
      # the caller can hand back a teardown. The prefix is applied here rather
      # than by the plugin author, so a plugin cannot declare into core's
      # namespace by accident or otherwise.
      def declare_plugin(plugin_name, &block)
        registry.declare(owner: plugin_name.to_s, prefix: "#{plugin_name}_", &block)
      end

      def undeclare(names) = registry.undeclare(names)

      # The sampling registry: anything sampled on the shared control-plane
      # tick (SampleGlobalMetricsJob) and refreshed on the /metrics scrape
      # path (MetricsController). Core samplers register themselves at
      # class-body-eval time; plugin samplers register through the manifest
      # `metrics do ... end` DSL (see Syrus::PluginApi::Definition#metrics) --
      # either a declarative `gauge :name do ... end` sample block, or a full
      # sampler class via `sampler SomeClass`. Either way, adding one requires
      # no change to SampleGlobalMetricsJob or MetricsController.
      def register_sampler(sampler) = registry.register_sampler(sampler)
      def unregister_sampler(sampler) = registry.unregister_sampler(sampler)
      def samplers = registry.samplers

      def counter(name) = registry.fetch(name, :counter)
      def gauge(name) = registry.fetch(name, :gauge)
      def histogram(name) = registry.fetch(name, :histogram)

      def definitions = registry.definitions

      # Renders the Prometheus text exposition format. Reads in-memory state
      # only; the callers that need global (cluster-wide) values refresh those
      # gauges before calling.
      def render = TextFormat.render(registry)

      # Test seam. Never call this from application code.
      def reset!
        @registry = Registry.new
      end
    end
  end
end
