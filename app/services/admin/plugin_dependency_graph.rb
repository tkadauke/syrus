module Admin
  # Walks the depends_on relationships declared on registered Syrus::Plugin::Manifest
  # records. Names are plugin names (strings), not manifest objects, so callers can
  # cheaply combine results with PluginRecord lookups.
  class PluginDependencyGraph
    def initialize(manifests = Syrus::PluginRegistry.all_plugins)
      @by_name = manifests.index_by(&:name)
    end

    # Transitive closure of plugins `name` depends on (its dependencies), not
    # including itself. Unknown names return an empty array.
    def dependencies_for(name, seen = Set.new)
      manifest = @by_name[name]
      return [] unless manifest

      Array(manifest.depends_on).flat_map do |dep_name|
        next [] if seen.include?(dep_name)

        seen << dep_name
        [ dep_name, *dependencies_for(dep_name, seen) ]
      end.uniq
    end

    # Transitive closure of plugins that depend on `name` (its dependents), not
    # including itself.
    def dependents_for(name)
      @by_name.keys.select { |candidate| candidate != name && transitively_depends_on?(candidate, name) }
    end

    private

    def transitively_depends_on?(name, target, seen = Set.new)
      return false if seen.include?(name)

      seen << name
      manifest = @by_name[name]
      return false unless manifest

      deps = Array(manifest.depends_on)
      return true if deps.include?(target)

      deps.any? { |dep_name| transitively_depends_on?(dep_name, target, seen) }
    end
  end
end
