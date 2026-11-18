require "pathname"
require "ripper"
require "syrus/plugin_host_surface/scanner"

module Syrus
  # Discovers plugin declarations before loading their Ruby entry files. This
  # keeps discovery independent of Bundler and lets external plugins use the
  # same boot path as the plugins shipped with Syrus.
  class PluginLoader
    class Error < StandardError; end

    Plugin = Data.define(:name, :directory, :entry_file, :dependencies, :required_dependencies, :external, :version, :requires_syrus)
    DEPENDENCY_DECLARATIONS = %w[depends_on optionally_depends_on].freeze
    FRAMEWORK_GEM_DEPENDENCIES = %w[rails].freeze
    RESCUED_ERRORS = [ LoadError, StandardError, ScriptError ].freeze

    class << self
      attr_reader :plugins_by_name

      def install_definition!(definition)
        plugin = @plugins_by_name&.fetch(definition.name, nil)
        existing_manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == definition.name }
        if existing_manifest && !existing_manifest.loaded && existing_manifest.metadata.to_h.key?(:load_state)
          definition.discard_engine!
          return existing_manifest
        end

        failed_dependency = plugin&.required_dependencies&.find do |name|
          manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == name }
          manifest && !manifest.loaded
        end
        if failed_dependency
          definition.discard_engine!
          return record_failure(plugin, RuntimeError.new("dependency #{failed_dependency} failed to load"),
            state: :skipped_dependency, message: "skipped because dependency #{failed_dependency} failed to load")
        end

        snapshot = Syrus::PluginRegistry.snapshot
        definition.install!
      rescue *RESCUED_ERRORS => e
        Syrus::PluginRegistry.restore(snapshot) if snapshot
        raise unless plugin && isolate?(plugin)

        definition.discard_engine!
        record_failure(plugin, e)
      end

      def isolate?(plugin)
        plugin.external || (defined?(Rails) && Rails.env.production?)
      end

      def record_failure(plugin, error, state: :failed, message: nil)
        message ||= "#{error.class}: #{error.message}"
        Syrus::PluginRegistry.record_load_failure(
          name: plugin.name, state: state, message: message,
          backtrace: error.backtrace, version: plugin.version, external: plugin.external,
          requires_syrus: plugin.requires_syrus, dependencies: plugin.dependencies
        )
      end

      def remember_plugins(plugins)
        @plugins_by_name = plugins.index_by(&:name)
      end

      # Plugin declarations must load before the application class is built so
      # Rails engines can participate in initialization. Host-surface scanning
      # cannot run that early: it needs application autoloading and the public
      # API registry installed by to_prepare.
      def scan_external_plugins!
        Syrus::PluginRegistry.all_plugins.select(&:external).each do |manifest|
          next unless manifest.plugin_root

          Syrus::PluginRegistry.record_host_surface_scan(manifest.name, scan_plugin_root(manifest.plugin_root))
        end
      end

      private

      def scan_plugin_root(directory)
        Syrus::PluginHostSurface::Scanner.cached(directory)
      rescue *RESCUED_ERRORS => error
        Syrus::PluginHostSurface::Scanner::Result.new(public: [], legacy: [], unlisted: [], dynamic: [],
          minimum_syrus_version: nil, content_hash: nil, error: "#{error.class}: #{error.message}")
      end
    end

    def self.load!(plugin_roots: Syrus::PluginRoots.default)
      new(plugin_roots:).load!
    end

    def initialize(plugin_roots:)
      @plugin_roots = plugin_roots
    end

    def load!
      plugins = safely_discovered_plugins
      self.class.remember_plugins(plugins)
      failed = Set.new
      order_plugins(plugins).each do |plugin|
        failed_dependency = plugin.required_dependencies.find { |name| failed.include?(name) }
        if failed_dependency
          self.class.record_failure(plugin, RuntimeError.new("dependency #{failed_dependency} failed to load"),
            state: :skipped_dependency, message: "skipped because dependency #{failed_dependency} failed to load")
          failed << plugin.name
          next
        end

        if plugin.external
          Syrus::PluginRegistry.register(name: plugin.name, version: plugin.version.to_s,
            requires_syrus: plugin.requires_syrus, external: true, loaded: compatible?(plugin),
            plugin_root: plugin.directory)
          next unless compatible?(plugin)
        end
        lib_dir = plugin.directory.join("lib").to_s
        $LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
        begin
          require plugin.entry_file.to_s
        rescue *RESCUED_ERRORS => e
          raise unless self.class.isolate?(plugin)

          self.class.record_failure(plugin, e)
          failed << plugin.name
        end
      end
    end

    def ordered_plugins
      order_plugins(unique_plugins(@plugin_roots.plugin_directories.map { |directory| inspect_plugin(directory) }))
    end

    def order_plugins(plugins)
      by_name = plugins.to_h { |plugin| [ plugin.name, plugin ] }
      pending = plugins.to_h { |plugin| [ plugin.name, plugin.dependencies.select { |name| by_name.key?(name) } ] }
      ordered = []

      until pending.empty?
        ready = pending.select { |_name, dependencies| dependencies.none? { |name| pending.key?(name) } }.keys.sort
        # Cycles are deliberately left to PluginHealth. Loading every member
        # preserves its existing diagnostics instead of turning a cycle into a
        # boot failure.
        ready = pending.keys.sort if ready.empty?
        ready.each do |name|
          ordered << by_name.fetch(name)
          pending.delete(name)
        end
      end

      ordered
    end

    private

    def safely_discovered_plugins
      inspected = @plugin_roots.plugin_directories.filter_map do |directory|
        inspect_plugin(directory)
      rescue *RESCUED_ERRORS => e
        raise unless @plugin_roots.external?(directory) || (defined?(Rails) && Rails.env.production?)

        record_discovery_failure(directory, e)
        nil
      end

      groups = inspected.group_by(&:name)
      groups.each_value do |candidates|
        next if candidates.one? || candidates.count { |candidate| !candidate.external }.one?

        message = "duplicate plugin name #{candidates.first.name.inspect}: #{candidates.map(&:directory).sort.join(', ')}"
        candidates.each do |plugin|
          self.class.record_failure(plugin, Error.new(message), state: :duplicate_name, message: message)
        end
      end
      groups.filter_map do |_name, candidates|
        built_in = candidates.reject(&:external)
        next built_in.first if built_in.one?
        next if candidates.many?

        candidates.first
      end
    end

    def record_discovery_failure(directory, error)
      name = directory.basename.to_s
      gemspec = directory.glob("*.gemspec").first
      if gemspec
        specification = Gem::Specification.load(gemspec.to_s) rescue nil
        name = specification.name if specification&.name
      end
      plugin = Plugin.new(name:, directory:, entry_file: directory.join("lib/#{name}.rb"), dependencies: [], required_dependencies: [],
        external: @plugin_roots.external?(directory), version: "unknown", requires_syrus: nil)
      self.class.record_failure(plugin, error)
    end

    def unique_plugins(plugins)
      plugins.group_by(&:name).map do |name, candidates|
        next candidates.first if candidates.one?

        built_in = candidates.reject(&:external)
        next built_in.first if built_in.one?

        paths = candidates.map(&:directory).sort.join(", ")
        raise Error, "Plugin name #{name.inspect} is declared by multiple manifests: #{paths}"
      end
    end
    def inspect_plugin(directory)
      gemspec = gemspec_for(directory)
      specification = Gem::Specification.load(gemspec.to_s)
      raise Error, "Plugin manifest #{gemspec} is invalid" unless specification

      entry_file = directory.join("lib", "#{specification.name}.rb")
      raise Error, "Plugin #{specification.name.inspect} is missing entry file #{entry_file}" unless entry_file.file?

      external = @plugin_roots.external?(directory)
      validate_external_dependencies!(specification, gemspec) if external
      requires_syrus = parse_requirement(specification.metadata["requires_syrus"], gemspec) if external

      Plugin.new(
        name: plugin_name(entry_file),
        directory: directory,
        entry_file: entry_file,
        dependencies: plugin_dependencies(entry_file),
        required_dependencies: plugin_dependencies(entry_file, declarations: [ "depends_on" ]),
        external: external,
        version: specification.version,
        requires_syrus: requires_syrus
      )
    end

    def compatible?(plugin)
      plugin.requires_syrus.nil? || SyrusVersion.release.nil? || plugin.requires_syrus.satisfied_by?(SyrusVersion.release)
    end

    def parse_requirement(value, gemspec)
      return if value.to_s.strip.empty?

      Gem::Requirement.new(value)
    rescue ArgumentError => e
      raise Error, "Plugin manifest #{gemspec} has malformed requires_syrus #{value.inspect}: #{e.message}"
    end
    def gemspec_for(directory)
      gemspecs = directory.glob("*.gemspec")
      return gemspecs.first if gemspecs.one?

      raise Error, "Plugin #{directory} must contain exactly one gemspec manifest"
    end

    def plugin_name(entry_file)
      source = entry_file.read
      match = source.match(/\bsyrus_plugin\s+["']([^"']+)["']/)
      raise Error, "Plugin entry file #{entry_file} does not declare syrus_plugin" unless match

      match[1]
    end

    def plugin_dependencies(entry_file, declarations: DEPENDENCY_DECLARATIONS)
      tokens = Ripper.lex(entry_file.read)
      dependencies = []
      tokens.each_with_index do |(_position, type, text, _state), index|
        next unless type == :on_ident && declarations.include?(text)

        bracket = ((index + 1)...tokens.length).find { |candidate| tokens[candidate][1] == :on_lbracket }
        next unless bracket

        depth = 0
        tokens.drop(bracket).each do |_position, token_type, token_text, _state|
          depth += 1 if token_type == :on_lbracket
          depth -= 1 if token_type == :on_rbracket
          dependencies << token_text if depth.positive? && token_type == :on_tstring_content
          break if depth.zero?
        end
      end
      dependencies.uniq
    end

    def validate_external_dependencies!(specification, gemspec)
      dependencies = specification.runtime_dependencies.map(&:name) - FRAMEWORK_GEM_DEPENDENCIES
      return if dependencies.empty?

      raise Error,
        "External plugin #{specification.name.inspect} may not declare gem dependencies; " \
        "remove #{dependencies.sort.join(', ')} from #{gemspec}"
    end
  end
end
