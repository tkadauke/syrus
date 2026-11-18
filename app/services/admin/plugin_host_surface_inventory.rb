require "prism"

module Admin
  class PluginHostSurfaceInventory
    Reference = Data.define(:constant, :plugin, :path, :line)
    CollectedReference = Data.define(:name, :nesting, :absolute, :line)
    Result = Data.define(:constant, :tier, :plugins, :count)

    SOURCE_GLOBS = %w[app/**/*.rb lib/**/*.rb].freeze
    NON_RUBY_APP_ROOTS = %w[assets frontend views].freeze

    class ConstantCollector < Prism::Visitor
      attr_reader :references, :definitions

      def initialize
        @references = []
        @definitions = []
        @nesting = []
      end

      def visit_class_node(node)
        record_definition(node.constant_path)
        visit(node.superclass) if node.superclass
        with_nesting(node.constant_path) { visit(node.body) if node.body }
      end

      def visit_module_node(node)
        record_definition(node.constant_path)
        with_nesting(node.constant_path) { visit(node.body) if node.body }
      end

      def visit_constant_path_node(node)
        name = constant_name(node)
        record_reference(name, node.location.start_line) if name
      end

      def visit_constant_read_node(node)
        record_reference(node.name.to_s, node.location.start_line)
      end

      def visit_constant_write_node(node)
        @definitions << qualify(node.name.to_s)
        super
      end

      private

      def record_reference(name, line)
        @references << CollectedReference.new(
          name: name.delete_prefix("::"),
          nesting: @nesting.dup,
          absolute: name.start_with?("::"),
          line:
        )
      end

      def record_definition(node)
        name = constant_name(node)
        @definitions << qualify(name) if name
      end

      def with_nesting(node)
        name = constant_name(node)
        previous = @nesting
        @nesting = [ qualify(name), *previous ]
        yield
      ensure
        @nesting = previous
      end

      def constant_name(node)
        node.respond_to?(:full_name) ? node.full_name : node.name.to_s
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      def qualify(name)
        return name.delete_prefix("::") if name.start_with?("::") || @nesting.empty?

        "#{@nesting.first}::#{name}"
      end
    end

    def initialize(root: Rails.root, surface: Syrus::PluginHostSurface.new)
      @root = Pathname.new(root)
      @surface = surface
    end

    def references
      @references ||= begin
        core = core_constants
        plugin_constants = plugin_constants_by_plugin
        plugin_files.flat_map do |plugin, path|
          collector = parse(path)
          owned_constants = plugin_constants.fetch(plugin).difference(core)
          collector.references.filter_map do |reference|
            resolved = resolve(reference, core, owned_constants)
            next unless resolved

            Reference.new(constant: resolved, plugin:, path: relative(path), line: reference.line)
          end
        end
      end
    end

    def results
      references.group_by(&:constant).map do |constant, refs|
        counts = refs.group_by(&:plugin).transform_values(&:count).sort.to_h
        Result.new(constant:, tier: @surface.lookup(constant)&.tier || "unlisted", plugins: counts, count: refs.size)
      end.sort_by(&:constant)
    end

    def references_for(directory)
      directory = Pathname.new(directory).expand_path
      files = SOURCE_GLOBS.flat_map { |glob| Dir.glob(directory.join(glob)).sort }.map { |path| Pathname.new(path) }
      collectors = files.to_h { |path| [ path, parse(path) ] }
      owned = collectors.values.each_with_object(Set.new) { |collector, constants| constants.merge(collector.definitions) }
      collectors.flat_map do |path, collector|
        collector.references.filter_map do |reference|
          resolved = resolve(reference, core_constants, owned)
          next unless resolved
          Reference.new(constant: resolved, plugin: directory.basename.to_s,
            path: path.relative_path_from(directory).to_s, line: reference.line)
        end
      end
    end

    def core_constants
      @core_constants ||= core_files.each_with_object(Set.new) do |path, constants|
        constants.merge(parse(path).definitions)
        path_constant = core_path_constant(path)
        constants << path_constant if path_constant
      end
    end

    private

    def plugin_files
      @plugin_files ||= plugin_directories.flat_map do |dir|
        SOURCE_GLOBS.flat_map { |glob| Dir.glob(dir.join(glob)).sort }.map { |path| [ dir.basename.to_s, Pathname.new(path) ] }
      end
    end

    def plugin_constants_by_plugin
      @plugin_constants_by_plugin ||= plugin_files.each_with_object(Hash.new { |hash, plugin| hash[plugin] = Set.new }) do |(plugin, path), constants|
        constants[plugin].merge(parse(path).definitions)
      end
    end

    def resolve(reference, core, plugin_constants)
      candidates(reference).each do |candidate, lexical_prefix_length|
        plugin_match = longest_constant_prefix(candidate, plugin_constants)
        resolved = longest_constant_prefix(candidate, core)
        plugin_match_length = plugin_match&.split("::")&.length.to_i
        core_match_length = resolved&.split("::")&.length.to_i
        resolved = nil if core_match_length <= lexical_prefix_length
        return if plugin_match_length > lexical_prefix_length && plugin_match_length >= core_match_length
        return resolved if resolved
      end

      nil
    end

    def candidates(reference)
      return [ [ reference.name, 0 ] ] if reference.absolute

      reference.nesting.map do |namespace|
        [ "#{namespace}::#{reference.name}", namespace.split("::").length ]
      end + [ [ reference.name, 0 ] ]
    end

    def longest_constant_prefix(name, constants)
      parts = name.split("::")
      parts.length.downto(1).map { |length| parts.first(length).join("::") }.find { |candidate| constants.include?(candidate) }
    end

    def core_files
      roots = core_app_roots + [ @root.join("lib/syrus") ]
      roots.flat_map { |dir| dir.directory? ? Dir.glob(dir.join("**/*.rb")).sort.map { |path| Pathname.new(path) } : [] }
    end

    def core_path_constant(path)
      relative_path = relative(path)
      if (match = relative_path.match(%r{\Aapp/[^/]+/(.+)\.rb\z}))
        match[1].camelize
      elsif (match = relative_path.match(%r{\Alib/(syrus/.+)\.rb\z}))
        match[1].camelize
      end
    end

    def core_app_roots
      app = @root.join("app")
      return [] unless app.directory?

      app.children.select(&:directory?).reject { |path| NON_RUBY_APP_ROOTS.include?(path.basename.to_s) }
    end

    def plugin_directories
      roots = Syrus::PluginRoots.new(application_root: @root)
      roots.plugin_directories.select { |directory| roots.built_in?(directory) }
    end

    def parse(path)
      result = Prism.parse_file(path.to_s)
      raise ArgumentError, "could not parse #{relative(path)}: #{result.errors.map(&:message).join(', ')}" unless result.success?

      ConstantCollector.new.tap { |collector| collector.visit(result.value) }
    end

    def relative(path) = Pathname.new(path).relative_path_from(@root).to_s
  end
end
