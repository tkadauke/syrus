require "pathname"
require "ripper"

module Syrus
  # Discovers plugin declarations before loading their Ruby entry files. This
  # keeps discovery independent of Bundler and lets external plugins use the
  # same boot path as the plugins shipped with Syrus.
  class PluginLoader
    class Error < StandardError; end

    Plugin = Data.define(:name, :directory, :entry_file, :dependencies, :external)
    DEPENDENCY_DECLARATIONS = %w[depends_on optionally_depends_on].freeze
    FRAMEWORK_GEM_DEPENDENCIES = %w[rails].freeze

    def self.load!(plugin_roots: Syrus::PluginRoots.default)
      new(plugin_roots:).load!
    end

    def initialize(plugin_roots:)
      @plugin_roots = plugin_roots
    end

    def load!
      ordered_plugins.each do |plugin|
        lib_dir = plugin.directory.join("lib").to_s
        $LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
        require plugin.entry_file.to_s
      end
    end

    def ordered_plugins
      plugins = @plugin_roots.plugin_directories.map { |directory| inspect_plugin(directory) }
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

    def inspect_plugin(directory)
      gemspec = gemspec_for(directory)
      specification = Gem::Specification.load(gemspec.to_s)
      raise Error, "Plugin manifest #{gemspec} is invalid" unless specification

      entry_file = directory.join("lib", "#{specification.name}.rb")
      raise Error, "Plugin #{specification.name.inspect} is missing entry file #{entry_file}" unless entry_file.file?

      external = @plugin_roots.external?(directory)
      validate_external_dependencies!(specification, gemspec) if external

      Plugin.new(
        name: plugin_name(entry_file),
        directory: directory,
        entry_file: entry_file,
        dependencies: plugin_dependencies(entry_file),
        external: external
      )
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

    def plugin_dependencies(entry_file)
      tokens = Ripper.lex(entry_file.read)
      dependencies = []
      tokens.each_with_index do |(_position, type, text, _state), index|
        next unless type == :on_ident && DEPENDENCY_DECLARATIONS.include?(text)

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
