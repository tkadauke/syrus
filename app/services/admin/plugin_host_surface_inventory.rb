require "prism"

module Admin
  class PluginHostSurfaceInventory
    Reference = Data.define(:constant, :plugin, :path, :line)
    Result = Data.define(:constant, :tier, :plugins, :count)

    SOURCE_GLOBS = %w[app/**/*.rb lib/**/*.rb].freeze
    NON_RUBY_APP_ROOTS = %w[assets frontend views].freeze

    class ConstantCollector < Prism::Visitor
      attr_reader :references, :definitions

      def initialize
        @references = []
        @definitions = []
        @namespace = []
      end

      def visit_class_node(node)
        record_definition(node.constant_path)
        visit(node.superclass) if node.superclass
        with_namespace(node.constant_path) { visit(node.body) if node.body }
      end

      def visit_module_node(node)
        record_definition(node.constant_path)
        with_namespace(node.constant_path) { visit(node.body) if node.body }
      end

      def visit_constant_path_node(node)
        name = constant_name(node)
        @references << [ name.delete_prefix("::"), node.location.start_line ] if name
      end

      def visit_constant_read_node(node)
        @references << [ node.name.to_s, node.location.start_line ]
      end

      def visit_constant_write_node(node)
        @definitions << qualify(node.name.to_s)
        super
      end

      private

      def record_definition(node)
        name = constant_name(node)
        @definitions << qualify(name) if name
      end

      def with_namespace(node)
        name = constant_name(node)
        previous = @namespace
        @namespace = name&.start_with?("::") ? name.delete_prefix("::").split("::") : previous + name.to_s.split("::")
        yield
      ensure
        @namespace = previous
      end

      def constant_name(node)
        node.respond_to?(:full_name) ? node.full_name : node.name.to_s
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      def qualify(name)
        return name.delete_prefix("::") if name.start_with?("::") || @namespace.empty?

        ([ *@namespace, name ]).join("::")
      end
    end

    def initialize(root: Rails.root, surface: Syrus::PluginHostSurface.new)
      @root = Pathname.new(root)
      @surface = surface
    end

    def references
      @references ||= begin
        core = core_constants
        plugin_constants = all_plugin_constants
        plugin_files.flat_map do |plugin, path|
          collector = parse(path)
          collector.references.filter_map do |name, line|
            resolved = resolve(name, core)
            next unless resolved
            next if owned_by_plugin?(name, plugin_constants)

            Reference.new(constant: resolved, plugin:, path: relative(path), line:)
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

    def all_plugin_constants
      @all_plugin_constants ||= plugin_files.each_with_object(Set.new) do |(_plugin, path), constants|
        constants.merge(parse(path).definitions)
      end
    end

    def owned_by_plugin?(name, plugin_constants)
      normalized = name.delete_prefix("::")
      plugin_constants.any? { |constant| normalized == constant || normalized.start_with?("#{constant}::") }
    end

    def resolve(name, core)
      normalized = name.delete_prefix("::")
      parts = normalized.split("::")
      parts.length.downto(1).map { |length| parts.first(length).join("::") }.find { |candidate| core.include?(candidate) }
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
