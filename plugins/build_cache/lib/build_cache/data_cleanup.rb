module BuildCache
  # Installed with `always`, not `while_enabled`: disabling this plugin stops
  # sccache config/stats capture, it does not delete the per-repository
  # settings row already saved, and it still has to go when its repository
  # does (see PluginDataCleanup / Syrus::DataCleanup).
  module DataCleanup
    def self.install_into(scope)
      scope.effect("repository build cache settings") do
        Syrus::DataCleanup.register("Repository", "build_cache.repository_settings") do |repository|
          BuildCache::RepositorySettings.for_repository(repository)&.destroy
        end
      end
    end
  end
end
