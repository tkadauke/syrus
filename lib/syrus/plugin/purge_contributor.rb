module Syrus
  module Plugin
    # Interface for `:purge_contributor`. Some plugins hold data on behalf of
    # other plugins outside the database -- Plugin Runtime keeps each
    # container-backed plugin's volumes. Syrus::PluginPurge asks every enabled
    # contributor what it holds for the plugin being purged, lists it in the
    # report, and asks it to remove it on purge, so purging a plugin removes
    # all of its data rather than only its tables.
    #
    # Implementations define (class methods):
    #
    #   purge_report(plugin_name) -> Array<String>
    #     One human-readable line per item held for that plugin
    #     ("volume syrus_plugin_git-mirror_data (1.2 GB)"). Empty when none.
    #   purge!(plugin_name) -> Array<String>
    #     Removes them and describes what was removed.
    #
    # Register an implementation at boot time:
    #   provides purge_contributor: "MyPlugin::PurgeContributor"
    module PurgeContributor
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def purge_report(_plugin_name)
          raise NotImplementedError, "#{name} must implement .purge_report"
        end

        def purge!(_plugin_name)
          raise NotImplementedError, "#{name} must implement .purge!"
        end
      end
    end
  end
end
