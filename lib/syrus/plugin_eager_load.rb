module Syrus
  # Keeps disabled plugins out of the eager load.
  #
  # Their `app/` directories still join the autoload paths -- a Rails engine
  # required through the Gemfile always does -- so Zeitwerk resolves their
  # constants on first reference and enabling a plugin needs no restart. What
  # this removes is the cost of loading code for features nobody can reach.
  module PluginEagerLoad
    module_function

    # Returns the directories that were excluded, so the caller (and its spec)
    # can see what happened rather than inferring it.
    def apply!(loader: Rails.autoloaders.main, root: nil, plugin_roots: nil, names: nil)
      names ||= Syrus::PluginRegistry.eager_load_skippable_plugin_names
      return [] if names.empty?

      roots = if plugin_roots
        names.filter_map { |name| plugin_roots.resolve(name)&.to_s }
      elsif root
        built_in_root = PluginRoots.new(application_root: root).built_in_root
        names.map { |name| built_in_root.join(name.to_s).to_s }
      else
        names.filter_map { |name| PluginRoots.default.resolve(name)&.to_s }
      end
      excluded = loader.dirs.select { |dir| roots.any? { |plugin_root| dir.start_with?("#{plugin_root}/") } }
      excluded.each { |dir| loader.do_not_eager_load(dir) }
      excluded
    end
  end
end
