module Syrus
  # A core kind table (Workflow::TriggerKind, Step::Kind, Job::Kind) plus
  # whatever plugins have installed into it.
  #
  # This used to merge plugin contributions on every read, cached against
  # PluginRegistry.generation. Reads are now a plain concatenation of the
  # built-in entries and an installed list: a plugin's kinds are *put here*
  # when it becomes active and taken away again when it does not, rather than
  # re-derived on demand. Disabling a plugin therefore removes its kinds
  # instead of relying on every cache downstream noticing.
  #
  # `Syrus::Installer.sync!` on read is what makes that safe across processes
  # -- see Installer for why a one-shot install is not enough here.
  class KindRegistry
    def initialize(built_in:, entry_class:, provider_method:, key: :kind, extension_point: :workflow_kinds, validate_plugin_entry: nil)
      @built_in = built_in.freeze
      @entry_class = entry_class
      @provider_method = provider_method
      @key = key
      @extension_point = extension_point
      @validate_plugin_entry = validate_plugin_entry
      @mutex = Mutex.new
      @installed = []

      Syrus::Installer.define("kinds:#{provider_method}") { |scope| install_into(scope) }
    end

    def entries
      Syrus::Installer.sync!
      @mutex.synchronize { (@built_in + @installed).freeze }
    end

    def by_key
      entries.index_by { |entry| entry.public_send(@key) }
    end

    # Installs every currently-provided plugin entry and returns the teardown
    # that removes exactly those again.
    def install_into(scope)
      scope.effect("#{@provider_method}") do
        added = plugin_entries
        next nil if added.empty?

        @mutex.synchronize { @installed.concat(added) }
        -> { @mutex.synchronize { added.each { |entry| @installed.delete(entry) } } }
      end
    end

    private

    def plugin_entries
      built_in_keys = @built_in.map { |entry| entry.public_send(@key).to_s }.to_set
      seen = Set.new

      Syrus::PluginRegistry.providers_for(@extension_point).flat_map do |provider|
        next [] unless provider.respond_to?(@provider_method)

        Array(provider.public_send(@provider_method)).filter_map do |attrs|
          attrs = attrs.to_h.symbolize_keys
          name = attrs[@key].to_s

          if @validate_plugin_entry && !@validate_plugin_entry.call(provider, attrs)
            Rails.logger.error("[KindRegistry] #{provider} declares invalid #{@provider_method} entry #{name.inspect}; ignoring")
            next
          end

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
