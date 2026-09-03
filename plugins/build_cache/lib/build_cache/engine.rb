module BuildCache
  class Engine < ::Rails::Engine
    config.after_initialize do
      Object.const_set(:SccacheStatsCapture, BuildCache::StatsCapture) unless Object.const_defined?(:SccacheStatsCapture)
      Workflow.const_set(:SccacheArtifact, BuildCache::StatsArtifact) unless Workflow.const_defined?(:SccacheArtifact)

      BuildCache.register!
    end
  end
end
