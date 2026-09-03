module Syrus
  # Merges plugin-contributed entries into a core kind registry.
  #
  # Kind tables (Workflow::TriggerKind, Step::Kind) are read on hot paths --
  # every label render, every dispatch -- so the merged result is cached and
  # keyed on PluginRegistry.generation rather than a clock. Invalidation is
  # then exact: enabling, disabling, or registering a plugin bumps the
  # generation and the next read rebuilds, with no staleness window and no
  # per-read rebuild in environments that disable time-based caches.
  class KindRegistry

    def initialize(built_in:, entry_class:, provider_method:, key: :kind)
      @built_in = built_in
      @entry_class = entry_class
      @provider_method = provider_method
      @key = key
      @mutex = Mutex.new
    end

    def entries
      generation = Syrus::PluginRegistry.generation

      @mutex.synchronize do
        return @cached if @cached && @cached_generation == generation

        @cached = (@built_in + plugin_entries).freeze
        @cached_generation = generation
        @cached
      end
    end

    def by_key
      entries.index_by { |entry| entry.public_send(@key) }
    end

    private

    def plugin_entries
      built_in_keys = @built_in.map { |entry| entry.public_send(@key).to_s }.to_set
      seen = Set.new

      Syrus::PluginRegistry.providers_for(:workflow_kinds).flat_map do |provider|
        next [] unless provider.respond_to?(@provider_method)

        Array(provider.public_send(@provider_method)).filter_map do |attrs|
          attrs = attrs.to_h.symbolize_keys
          name = attrs[@key].to_s

          # Core keeps its own. Letting a plugin shadow a built-in kind would
          # make workflow behavior depend on plugin load order.
          if built_in_keys.include?(name)
            Rails.logger.error("[KindRegistry] #{provider} declares #{name.inspect}, which is a built-in kind; ignoring")
            next
          end

          if seen.include?(name)
            Rails.logger.error("[KindRegistry] #{provider} redeclares #{name.inspect}, already contributed by another plugin; ignoring")
            next
          end

          seen << name
          @entry_class.new(**attrs)
        end
      rescue StandardError => e
        Rails.logger.error("[KindRegistry] #{provider}.#{@provider_method} failed: #{e.class}: #{e.message}")
        []
      end
    end
  end
end
