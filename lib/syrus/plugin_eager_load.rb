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
    def apply!(loader: Rails.autoloaders.main, root: Rails.root, names: nil)
      names ||= Syrus::PluginRegistry.eager_load_skippable_plugin_names
      return [] if names.empty?

      roots = names.map { |name| File.join(root.to_s, "plugins", name.to_s) }
      excluded = loader.dirs.select { |dir| roots.any? { |plugin_root| dir.start_with?("#{plugin_root}/") } }
      excluded.each { |dir| loader.do_not_eager_load(dir) }
      excluded
    end
  end
end
