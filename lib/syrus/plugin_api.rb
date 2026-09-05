module Syrus
  # The whole plugin interface: one file per plugin, declaring identity,
  # contributions, and effects. The framework owns *when* each of those runs,
  # because that turned out to be the thing plugin authors got wrong.
  #
  #   module Throughput
  #     extend Syrus::PluginApi
  #
  #     syrus_plugin "throughput" do
  #       display_name "Throughput"
  #       category     "observability"
  #       description  "Delivery throughput and landing waste."
  #
  #       provides ui_slot: "Throughput::UiSlots"
  #       route :get, "/api/v1/app/repositories/:repository_id/throughput_metrics",
  #             to: "api/v1/app/repository_throughput#show"
  #
  #       while_enabled do |scope|
  #         scope.effect("filter subject") { Filters.register_subject(...) }
  #       end
  #     end
  #   end
  #
  # This file is required explicitly from config/application.rb before
  # Bundler.require, and excluded from autoloading. It has to exist at *gem
  # load* time -- long before Zeitwerk or the rest of Syrus is available -- so
  # it must not reference anything outside itself at load time. Everything it
  # touches (Syrus::PluginRegistry, Syrus::Installer, the provider constants)
  # is resolved later, inside `to_prepare`.
  module PluginApi
    class Error < StandardError; end

    def syrus_plugin(name, &block)
      raise Error, "syrus_plugin requires a block" unless block

      # Rails::Engine.inherited infers the engine root from the call stack, and
      # from in here that is Syrus's own lib/ -- which resolves to the app root
      # and would hand the engine the whole application's paths. The plugin's
      # own lib/ is the only correct answer, and `called_from` is the only
      # window to say so: reading or writing `config` first triggers the
      # inference and raises.
      lib_dir = File.dirname(caller_locations(1, 1).first.absolute_path)

      definition = Definition.new(name: name.to_s, namespace: self, lib_dir: lib_dir)
      definition.instance_eval(&block)
      definition.build!
      @syrus_plugin_definition = definition
    end

    def syrus_plugin_definition = @syrus_plugin_definition

    # Registers now, rather than waiting for the next `to_prepare`. The engine
    # calls this itself; specs that reset the registry call it to put their
    # plugin back.
    def register! = syrus_plugin_definition.install!

    # One definition, instead of the same three lines copy-pasted into every
    # plugin -- which had drifted into two different meanings: eleven checked
    # the manifest's enabled flag, three asked whether the plugin's providers
    # were actually being handed out, which additionally accounts for health.
    #
    # The second is the one that matches what callers mean by "enabled": a
    # plugin whose hard dependency is disabled has its contributions withheld,
    # so reporting it as enabled would be a lie its own tools then act on.
    def enabled?
      name = syrus_plugin_definition.name
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == name }
      return false unless manifest&.enabled?

      Syrus::PluginRegistry.health.healthy?(name)
    end

    # Collects the declaration, then builds the engine and the registration
    # from it. Every setter is a plain reader when called with no argument, so
    # the definition can be introspected by specs and by the plugin itself.
    class Definition
      SCALARS = %i[
        display_name description long_description homepage icon_url author category
        version default_enabled disableable home_queue tick_interval prepare_priority
      ].freeze

      LISTS = %i[depends_on optionally_depends_on conflicts_with hosts config_schema].freeze

      attr_reader :name, :namespace, :lib_dir

      def initialize(name:, namespace:, lib_dir:)
        @name = name
        @namespace = namespace
        @lib_dir = lib_dir
        @scalars = { default_enabled: true, disableable: true, home_queue: :default, prepare_priority: 100 }
        @lists = {}
        @provides = {}
        @routes = []
        @frontend = {}
        @effects = []
        @boot_blocks = []
      end

      SCALARS.each do |field|
        define_method(field) do |*args|
          return @scalars[field] if args.empty?

          @scalars[field] = args.first
        end
      end

      LISTS.each do |field|
        define_method(field) do |*args|
          return @lists.fetch(field, []) if args.empty?

          @lists[field] = args.flatten
        end
      end

      # Contribution classes are named as strings, resolved at registration.
      # A constant captured here would be captured once and go stale on the
      # next reload; a string is re-resolved every time, and cannot be
      # referenced before the plugin's own autoload paths exist.
      def provides(pairs = {})
        return @provides if pairs.empty?

        @provides.merge!(pairs)
      end

      def route(verb, path, to:)
        @routes << { verb: verb.to_s.upcase, path: path, controller: to }
      end

      def frontend(pairs = {})
        return @frontend if pairs.empty?

        @frontend.merge!(pairs)
      end

      # Effects that belong to the plugin being *enabled*: torn down when it is
      # disabled, reinstalled when it is enabled again.
      def while_enabled(label = nil, &block)
        @effects << { scoped: true, label: label, block: block }
      end

      # Effects that must hold whether the plugin is enabled or not. Owning
      # rows on a core record is the case that matters: disabling a plugin
      # stops it doing work, it does not orphan the data it already wrote, and
      # that data still has to go when its owner does.
      def always(label = nil, &block)
        @effects << { scoped: false, label: label, block: block }
      end

      # The escape hatch for process-level work that is not a registration at
      # all -- a daemon a worker process owns, say. Runs on every to_prepare
      # like everything else, so the block must be safe to re-enter; there is
      # no teardown, which is exactly why it is not an effect.
      def on_boot(&block)
        @boot_blocks << block
      end

      def effects = @effects
      def routes = @routes

      def build!
        build_engine!
        namespace.const_set(:Engine, @engine) unless namespace.const_defined?(:Engine, false)
      end

      private

      def build_engine!
        definition = self
        @engine = Class.new(::Rails::Engine)
        # Must precede any `config` access -- see the note in #syrus_plugin.
        @engine.called_from = lib_dir

        @engine.config.to_prepare { definition.install! }
        @engine
      end

      public

      # Runs on every `to_prepare`: at boot, and again after each code reload.
      # lib/ is autoloadable, so the registry it writes into is itself replaced
      # on reload -- registering once per boot would silently unregister the
      # plugin on the developer's first file save.
      def install!
        Syrus::PluginRegistry.register(**manifest_arguments)
        install_effects!
        @boot_blocks.each(&:call)
      end

      def manifest_arguments
        {
          name: name,
          version: version || Syrus::PluginApi.default_version,
          provides: resolved_provides,
          routes: (routes if routes.any?),
          frontend: (frontend if frontend.any?)
        }.merge(
          SCALARS.each_with_object({}) { |field, args| args[field] = @scalars[field] unless field == :version }.compact
        ).merge(
          LISTS.each_with_object({}) { |field, args| args[field] = @lists[field] if @lists.key?(field) }
        ).compact
      end

      def resolved_provides
        @provides.each_with_object({}) do |(point, value), resolved|
          resolved[point] =
            if value.is_a?(Array)
              value.map { |entry| contribution(point, entry) }
            else
              contribution(point, value)
            end
        end
      end

      private

      def resolve_constant(value)
        return value unless value.is_a?(String) || value.is_a?(Symbol)

        Object.const_get(value.to_s)
      rescue NameError => e
        raise Error, "#{name} declares #{value.inspect}, which does not resolve to a constant (#{e.message})"
      end

      # The registry requires a contribution to include its extension point's
      # interface, so fourteen engines reopened their own classes at boot to
      # add it -- and those includes were lost on the next reload, because the
      # class comes back fresh. Core already knows which interface each point
      # takes; deriving it is both less to write and impossible to forget.
      def contribution(point, value)
        klass = resolve_constant(value)
        interface = Syrus::PluginRegistry::INTERFACE_FOR[point.to_sym]
        return klass unless interface

        module_ = interface.call
        klass.include(module_) unless klass.include?(module_)
        klass
      end

      def install_effects!
        @effects.each_with_index do |effect, index|
          kind = effect[:scoped] ? "while_enabled" : "always"
          # Stable across reloads, which is what the Installer keys on.
          label = effect[:label] ? "#{name}:#{effect[:label]}" : "#{name}:#{kind}:#{index}"
          # `always` is still scoped to the plugin -- just to a weaker
          # condition. It exists so disabling does not orphan rows the plugin
          # wrote; a plugin that was never enabled here wrote none.
          requires = effect[:scoped] ? :enabled : :ever_enabled

          Syrus::Installer.define(label, plugin: name, requires: requires, &effect[:block])
        end
      end
    end

    # Bundled plugins ship with the app, so their gem version carries no
    # information -- all thirty said "0.1.0". A plugin that genuinely versions
    # independently can still declare one.
    def self.default_version = "0.1.0"
  end
end
